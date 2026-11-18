#!/usr/bin/env cabal
{- cabal:
build-depends:
    aeson
  , aeson-pretty
  , base
  , bytestring
  , directory
  , filepath
  , optparse-applicative
  , text
  , time
  , typed-process
default-language: GHC2021
default-extensions:
    DuplicateRecordFields
  , LambdaCase
  , NamedFieldPuns
  , OverloadedRecordDot
  , OverloadedStrings
ghc-options: -Wall
-}
{-# LANGUAGE CPP #-}

-- GlaHiCo — opt-in LLM code review for GHC merge requests. See DESIGN.md.

module Main (main) where

import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, object, toJSON, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Encode.Pretty qualified as AP
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAlphaNum, isAscii, isDigit, isHexDigit, isSpace, toLower)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, nub, stripPrefix)
import Data.Maybe (catMaybes, fromMaybe, isJust, mapMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import GHC.Generics (Generic)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), die)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Process.Typed (byteStringInput, nullStream, proc, readProcess, runProcess, setEnv, setStdin, setWorkingDir)
import Text.Printf (printf)

--------------------------------------------------------------------------------
-- Options & CLI
--------------------------------------------------------------------------------

data Adhoc = AdhocText Text | AdhocFile FilePath

data Cmd = ReviewCmd Opts | PublishCmd PublishOpts

data PublishOpts = PublishOpts
  { runArg :: FilePath
  , reviewsRepo :: Maybe GitHubRepo
  , mode :: PublishMode
  }

data PublishMode
  = -- | Post the review.
    Post
  | -- | Print the title and body that would be posted.
    DryRun
  | -- | Write the review as it would be posted in a GitHub issue to files
    -- in the run directory, for someone to make the issue by hand.
    IssueFile
  | -- | Write the review as a comment for a GitHub pull request, folded
    -- away in a @<details>@ block, to a file in the run directory.
    CommentFile
  deriving (Eq)

data Opts = Opts
  { target :: String
  , finderModel :: String
  , verifierModel :: String
  , finderEffort :: String
  , verifierEffort :: String
  , adhoc :: Maybe Adhoc
  }

-- | @glahico publish RUN_DIR@ is a subcommand; a bare TARGET still reviews.
-- No real target collides with the literal word "publish" (targets are
-- digits, !N, URLs, or ..-ranges), so the fallback is unambiguous.
cmdP :: Parser Cmd
cmdP =
  hsubparser
    ( command
        "publish"
        ( info
            (PublishCmd <$> publishOptsP)
            (progDesc "Publish a run's review.md: as a GitHub issue for a pull request, as a GitLab snippet otherwise")
        )
        <> metavar "publish"
    )
    <|> (ReviewCmd <$> optsP)

publishOptsP :: Parser PublishOpts
publishOptsP =
  PublishOpts
    <$> strArgument (metavar "RUN_DIR|REVIEW_MD" <> help "Run directory containing review.md, or the review.md file itself")
    <*> optional
      ( option
          (maybeReader (parseGitHubRepo . T.pack))
          ( long "reviews-repo"
              <> metavar "OWNER/REPO"
              <> help "GitHub repository to post the issue in; required to publish the review of a pull request"
          )
      )
    <*> ( flag' DryRun (long "dry-run" <> help "Print the title and body that would be posted, and post nothing")
            <|> flag'
              IssueFile
              ( long "issue-file"
                  <> help "Write the review as it would be posted in a GitHub issue to issue.md in the run directory, and its title to issue-title.txt, and post nothing"
              )
            <|> flag'
              CommentFile
              ( long "comment-file"
                  <> help "Write the review as a comment for a GitHub pull request, folded in a <details> block, to comment.md in the run directory, and post nothing"
              )
            <|> pure Post
        )

optsP :: Parser Opts
optsP =
  Opts
    <$> strArgument
      (metavar "TARGET" <> help "MR number (14892 or !14892), gitlab.haskell.org MR URL, github.com pull request URL, local commit range (BASE..HEAD), or single commit")
    <*> strOption
      (long "finder-model" <> metavar "ALIAS" <> value "opus" <> showDefault <> help "Model for the finder stage (passed to `claude --model`: alias like opus/sonnet, or full ID like claude-opus-4-6)")
    <*> strOption
      (long "verifier-model" <> metavar "ALIAS" <> value "opus" <> showDefault <> help "Model for the verifier stage (same syntax as --finder-model)")
    <*> effortOption "finder-effort" "Effort level for the finder stage"
    <*> effortOption "verifier-effort" "Effort level for the verifier stage"
    <*> optional
      ( AdhocText
          <$> strOption (long "prompt" <> metavar "TEXT" <> help "Extra instructions appended to the finder prompt")
          <|> AdhocFile
            <$> strOption (long "prompt-file" <> metavar "PATH" <> help "File with extra instructions appended to the finder prompt")
      )

effortOption :: String -> String -> Parser String
effortOption name h =
  option
    (eitherReader check)
    (long name <> metavar "LEVEL" <> value "medium" <> showDefault <> help (h <> " (low|medium|high|xhigh|max)"))
  where
    check s
      | s `elem` ["low", "medium", "high", "xhigh", "max"] = Right s
      | otherwise = Left ("invalid effort level: " <> s)

--------------------------------------------------------------------------------
-- Target parsing
--------------------------------------------------------------------------------

-- | RangeTarget carries the base and head specs; empty sides default to HEAD.
data Target
  = MrTarget Text Int
  | PrTarget GitHubRepo PrNumber
  | RangeTarget Text Text
  | CommitTarget Text

-- | A repository on github.com, written @OWNER/REPO@.
newtype GitHubRepo = GitHubRepo Text

-- | A pull request's number within its repository.
newtype PrNumber = PrNumber Int

parseTarget :: String -> Either String Target
parseTarget s
  | null s = Left "empty target"
  | all isDigit s = Right (MrTarget "ghc/ghc" (read s))
  | '!' : ds <- s, not (null ds), all isDigit ds = Right (MrTarget "ghc/ghc" (read ds))
  | Just rest <- stripPrefix "https://gitlab.haskell.org/" s = parseMrUrl rest
  | Just rest <- stripPrefix "https://github.com/" s = parsePrUrl rest
  | "http://" `isPrefixOf` s || "https://" `isPrefixOf` s =
      Left "only gitlab.haskell.org merge-request URLs and github.com pull-request URLs are supported"
  | (a, rest) <- T.breakOn ".." (T.pack s)
  , Just b <- T.stripPrefix ".." rest =
      Right (RangeTarget (orHead a) (orHead (T.dropWhile (== '.') b)))
  -- Anything else is taken as a single commit; git validates the rev.
  | otherwise = Right (CommitTarget (T.pack s))
  where
    orHead t = if T.null t then "HEAD" else t

parseMrUrl :: String -> Either String Target
parseMrUrl rest
  | (proj, tl) <- T.breakOn "/-/merge_requests/" (T.pack rest)
  , Just tl' <- T.stripPrefix "/-/merge_requests/" tl
  , ds <- T.takeWhile isDigit tl'
  , not (T.null ds)
  , not (T.null proj) =
      Right (MrTarget proj (read (T.unpack ds)))
  | otherwise = Left ("cannot parse GitLab MR URL: https://gitlab.haskell.org/" <> rest)

-- | Parse what follows @https://github.com/@ in a pull request URL:
-- @OWNER/REPO/pull/N@, optionally followed by a tab (@/files@), a query or
-- a fragment. The owner and repository end up in a directory name and an
-- API path, so only the characters GitHub allows in them are accepted.
parsePrUrl :: String -> Either String Target
parsePrUrl rest = case T.splitOn "/" (T.pack rest) of
  owner : repo : "pull" : n : _
    | Just ghRepo <- parseGitHubRepo (owner <> "/" <> repo)
    , ds <- T.takeWhile isDigit n
    , not (T.null ds)
    , T.all (`elem` ("/?#" :: String)) (T.take 1 (T.drop (T.length ds) n)) ->
        Right (PrTarget ghRepo (PrNumber (read (T.unpack ds))))
  _ -> Left ("cannot parse GitHub pull request URL: https://github.com/" <> rest)

-- | Accept @OWNER/REPO@ where both parts are names GitHub could have issued.
parseGitHubRepo :: Text -> Maybe GitHubRepo
parseGitHubRepo t = case T.splitOn "/" t of
  [owner, repo] | nameOk owner, nameOk repo -> Just (GitHubRepo t)
  _ -> Nothing
  where
    nameOk x =
      not (T.null x)
        && x `notElem` [".", ".."]
        && T.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("-_." :: String))) x

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

tshow :: Show a => a -> Text
tshow = T.pack . show

dup :: a -> (a, a)
dup x = (x, x)

-- | Render a non-negative number with thousands separators: 35742 → "35,742".
commaSep :: Int -> Text
commaSep = T.pack . reverse . intercalate "," . chunk . reverse . show
  where
    chunk [] = []
    chunk s = take 3 s : chunk (drop 3 s)

warn :: String -> IO ()
warn s = hPutStrLn stderr ("Warning: " <> s)

lbsText :: BL.ByteString -> Text
lbsText = TE.decodeUtf8Lenient . BL.toStrict

-- | Capture stdout; hard error (showing stderr) on failure.
capture :: String -> [String] -> IO BL.ByteString
capture cmd args =
  tryCapture cmd args
    >>= either (\e -> die (unwords (cmd : args) <> " failed:\n" <> T.unpack e)) pure

tryCapture :: String -> [String] -> IO (Either Text BL.ByteString)
tryCapture cmd args = do
  (ec, out, err) <- readProcess (setStdin nullStream (proc cmd args))
  pure $ case ec of
    ExitSuccess -> Right out
    ExitFailure n -> Left ("exit code " <> tshow n <> "\n" <> lbsText err)

-- | Like 'capture', but with extra environment variables (merged into the
-- inherited environment) and a stdin body. Secrets go in @extraEnv@, never
-- argv, so the error message cannot leak them.
captureWith :: [(String, String)] -> BL.ByteString -> String -> [String] -> IO BL.ByteString
captureWith extraEnv body cmd args = do
  env <- getEnvironment
  (ec, out, err) <-
    readProcess (setEnv (extraEnv ++ env) (setStdin (byteStringInput body) (proc cmd args)))
  case ec of
    ExitSuccess -> pure out
    ExitFailure n ->
      die (unwords (cmd : args) <> " failed (exit " <> show n <> "):\n" <> T.unpack (lbsText err))

-- | Run with all streams inherited: git's own progress output is the progress story.
inherit :: String -> [String] -> IO ()
inherit cmd args = do
  ec <- runProcess (proc cmd args)
  case ec of
    ExitSuccess -> pure ()
    ExitFailure n -> die (unwords (cmd : args) <> " failed (exit " <> show n <> ")")

gitIn :: FilePath -> [String] -> IO Text
gitIn dir args = T.strip . lbsText <$> capture "git" ("-C" : dir : args)

gitOut :: FilePath -> [String] -> IO Text
gitOut dir args = lbsText <$> capture "git" ("-C" : dir : args)

gitLoud :: FilePath -> [String] -> IO ()
gitLoud dir args = inherit "git" ("-C" : dir : args)

shellQuote :: String -> String
shellQuote s
  | not (null s) && all (`elem` safe) s = s
  | otherwise = "'" <> concatMap esc s <> "'"
  where
    safe = ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ "._-/=:+,@%"
    esc '\'' = "'\\''"
    esc c = [c]

--------------------------------------------------------------------------------
-- JSON access
--------------------------------------------------------------------------------

vKey :: Key.Key -> Value -> Maybe Value
vKey k (Object o) = KM.lookup k o
vKey _ _ = Nothing

vText :: Key.Key -> Value -> Maybe Text
vText k v = case vKey k v of
  Just (String t) -> Just t
  _ -> Nothing

vInt :: Key.Key -> Value -> Maybe Int
vInt k v = case vKey k v of
  Just (Number n) -> Just (round n)
  _ -> Nothing

vArray :: Key.Key -> Value -> [Value]
vArray k v = case vKey k v of
  Just (Array xs) -> toList xs
  _ -> []

vBoolIs :: Key.Key -> Bool -> Value -> Bool
vBoolIs k b v = vKey k v == Just (Bool b)

reqText :: String -> Key.Key -> Value -> IO Text
reqText what k v = maybe (die (what <> ": missing field " <> show k)) pure (vText k v)

--------------------------------------------------------------------------------
-- glab api
--------------------------------------------------------------------------------

tryGlabJson :: String -> IO (Either Text Value)
tryGlabJson endpoint = do
  r <- tryCapture "glab" ["api", "--hostname", "gitlab.haskell.org", endpoint]
  pure $ case r of
    Left e -> Left e
    Right out -> either (Left . T.pack) Right (eitherDecode out)

glabJson :: String -> IO Value
glabJson endpoint =
  tryGlabJson endpoint
    >>= either (\e -> die ("glab api " <> endpoint <> " failed:\n" <> T.unpack e)) pure

--------------------------------------------------------------------------------
-- gh api
--------------------------------------------------------------------------------

ghJson :: String -> IO Value
ghJson endpoint = do
  out <- capture "gh" ["api", "--hostname", "github.com", endpoint]
  either (\e -> die ("gh api " <> endpoint <> ": cannot parse the response as JSON: " <> e)) pure (eitherDecode out)

--------------------------------------------------------------------------------
-- Publishing snippets
--------------------------------------------------------------------------------

-- | URL-encoded project whose snippets host published reviews.
publishProject :: String
publishProject = "sjakobi%2FGlaHiCo"

-- | Publishing needs a write-capable token; the tokens glab and gh are
-- configured with are for reading. Both tools prefer a token in the
-- environment over their config, so only this step gains write access.
--
-- The token file is root-owned so that agents running as the user cannot
-- read it; sudo prompts for the password on the controlling tty (and fails
-- immediately when there is none, i.e. in agent-spawned processes).
-- @howToCreate@ is the part of the not-found message that says which token
-- to make.
publishToken :: FilePath -> String -> IO String
publishToken path howToCreate = do
  exists <- doesFileExist path
  unless exists $
    die
      ( path <> " not found.\n"
          <> howToCreate
          <> "(single line), then make it root-only:\n"
          <> "  sudo chown root:root " <> path <> " && sudo chmod 600 " <> path
      )
  putStrLn "Reading token (sudo will prompt for your password) ..."
  T.unpack . T.strip . lbsText <$> capture "sudo" ["cat", path]

-- | Where a published review ended up, as recorded in @snippet.json@.
data Published = Published {publishedId :: Int, publishedUrl :: Text, host :: Text}

-- | The argument may be the run directory or the review.md file itself.
runPublish :: FilePath -> PublishOpts -> IO ()
runPublish dataDir opts = do
  let arg = opts.runArg
  argIsFile <- doesFileExist arg
  let runDir = if argIsFile then takeDirectory arg else arg
      reviewPath = if argIsFile then arg else runDir </> "review.md"
      snippetPath = runDir </> "snippet.json"
  haveReview <- doesFileExist reviewPath
  unless haveReview $ die (reviewPath <> " not found")
  published <- doesFileExist snippetPath
  when (published && opts.mode == Post) $ do
    prev <- eitherDecode <$> BL.readFile snippetPath
    let url = either (const "?") (fromMaybe "?" . vText "web_url") prev
    die
      ( snippetPath <> " already exists (published at " <> T.unpack url <> ").\n"
          <> "Delete it to publish this run again."
      )
  review <- TIO.readFile reviewPath
  let title = case T.lines review of
        (l : _) | Just t <- T.stripPrefix "# " l -> t
        _ -> "GlaHiCo review"
  forge <- runForge runDir
  let (postTitle, postBody) = case forge of
        Just "github" -> (inertTitle title, issueBody review)
        _ -> (title, review)
  case opts.mode of
    DryRun -> do
      TIO.putStrLn ("Title: " <> postTitle)
      TIO.putStrLn ""
      TIO.putStr postBody
    IssueFile -> do
      -- Whatever the run's target was, the files are for a GitHub issue.
      let body = issueBody review
          bodyPath = runDir </> "issue.md"
          titlePath = runDir </> "issue-title.txt"
      warnIfTooLong "an issue body" body
      TIO.writeFile bodyPath body
      TIO.writeFile titlePath (inertTitle title <> "\n")
      putStrLn titlePath
      putStrLn bodyPath
    CommentFile -> do
      let body = commentBody title review
          bodyPath = runDir </> "comment.md"
      warnIfTooLong "a comment" body
      TIO.writeFile bodyPath body
      putStrLn bodyPath
    Post -> do
      done <- case forge of
        Just "github" -> case opts.reviewsRepo of
          Just repo -> publishIssue dataDir repo postTitle postBody
          Nothing ->
            die
              ( "this run reviewed a GitHub pull request, which is published as an issue;\n"
                  <> "say which repository to post it in with --reviews-repo OWNER/REPO"
              )
        _ -> publishSnippet dataDir postTitle postBody
      now <- getCurrentTime
      BL.writeFile snippetPath $
        AP.encodePretty $
          object
            [ "id" .= done.publishedId
            , "web_url" .= done.publishedUrl
            , "project" .= done.host
            , "published_at" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
            ]
      putStrLn (T.unpack done.publishedUrl)

-- | GitHub limits an issue body and a comment to the same length.
warnIfTooLong :: String -> Text -> IO ()
warnIfTooLong what body =
  when (T.length body > issueBodyLimit) $
    warn
      ( "the review is " <> show (T.length body) <> " characters; GitHub limits " <> what <> " to "
          <> show issueBodyLimit
      )

-- | The forge recorded when the run was made. Runs from before
-- @target.json@ existed have none and are published as snippets.
runForge :: FilePath -> IO (Maybe Text)
runForge runDir = do
  let path = runDir </> "target.json"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else
      eitherDecode <$> BL.readFile path
        >>= either (\e -> die (path <> ": " <> e)) (pure . vText "forge")

publishSnippet :: FilePath -> Text -> Text -> IO Published
publishSnippet dataDir title review = do
  let body =
        A.encode $
          object
            [ "title" .= title
            , "visibility" .= ("internal" :: Text)
            , "files" .= [object ["file_path" .= ("review.md" :: Text), "content" .= review]]
            ]
  token <-
    publishToken (dataDir </> "gitlab-token") $
      "Create an access token with scope `api` (a project access token on\n"
        <> "sjakobi/GlaHiCo is preferred over a personal one), save it there\n"
  out <-
    captureWith
      [("GITLAB_TOKEN", token)]
      body
      "glab"
      [ "api"
      , "--hostname"
      , "gitlab.haskell.org"
      , "-X"
      , "POST"
      , "-H"
      , "Content-Type: application/json"
      , "--input"
      , "-"
      , "projects/" <> publishProject <> "/snippets"
      ]
  resp <- either (\e -> die ("snippet response: " <> e)) pure (eitherDecode out)
  sid <- maybe (die "snippet response: missing field id") pure (vInt "id" resp)
  url <- reqText "snippet response" "web_url" resp
  pure Published {publishedId = sid, publishedUrl = url, host = T.pack publishProject}

-- | GitHub's limit on the length of an issue body, in characters.
issueBodyLimit :: Int
issueBodyLimit = 65536

-- | Post a review of a pull request as an issue in the reviews repository.
-- Nothing is written to the repository the pull request belongs to.
publishIssue :: FilePath -> GitHubRepo -> Text -> Text -> IO Published
publishIssue dataDir (GitHubRepo repo) title body = do
  when (T.length body > issueBodyLimit) $
    die
      ( "the review is " <> show (T.length body) <> " characters; GitHub limits an issue body to "
          <> show issueBodyLimit
      )
  token <-
    publishToken (dataDir </> "github-token") $
      "Create a fine-grained personal access token whose only permission is\n"
        <> "read and write access to Issues on " <> T.unpack repo <> ", save it there\n"
  out <-
    captureWith
      [("GH_TOKEN", token)]
      (A.encode (object ["title" .= title, "body" .= body]))
      "gh"
      [ "api"
      , "--hostname"
      , "github.com"
      , "-X"
      , "POST"
      , "-H"
      , "Content-Type: application/json"
      , "--input"
      , "-"
      , "repos/" <> T.unpack repo <> "/issues"
      ]
  resp <- either (\e -> die ("issue response: " <> e)) pure (eitherDecode out)
  number <- maybe (die "issue response: missing field number") pure (vInt "number" resp)
  url <- reqText "issue response" "html_url" resp
  pure Published {publishedId = number, publishedUrl = url, host = repo}

{- Note [Inert references]
~~~~~~~~~~~~~~~~~~~~~~~~~~
A review of a pull request is published as an issue in another repository,
and the pull request should show nothing of it but the link someone chooses
to post there. GitHub, though, adds a "mentioned this" entry to the timeline
of any issue or pull request that an issue body refers to, and notifies any
user it mentions. A review refers to its target in the disclosure, and the
verifier's writeups are model output that may refer to anything.

So the published copy has its references made inert, the way Renovate does
for the changelogs it quotes:

  * links to github.com go through redirect.github.com, which forwards to
    the same page but is not recognised as a reference;
  * `#123`, `owner/repo#123`, `GH-123` and `@user` get a zero-width space
    after the `#`, `-` or `@`, so they read the same but are not linked.

One more change is not about references. A review opens with a list of
links to its findings, `[f1: ...](#f1-...)`. GitHub gives the headings of an
issue body no anchors, so in an issue those links go nowhere; the published
copy keeps their text and drops the link.

Fenced code blocks and code spans are left alone: GitHub links nothing
inside them, and the snippets there are quoted from the checkout verbatim.
The pass is mechanical and is disclosed in a note appended to the issue;
review.md in the run directory stays as generated.
-}

-- | The body of the issue for a review: the review with its references made
-- inert, and a note saying so. See Note [Inert references].
issueBody :: Text -> Text
issueBody review =
  T.stripEnd (inertRefs review)
    <> "\n\n"
    <> "_In this published copy, references to GitHub issues, pull requests and"
    <> " users were made inert mechanically, so that the review does not appear"
    <> " on their timelines or notify anyone: links to github.com go through"
    <> " redirect.github.com, and a zero-width space follows `#` and `@`."
    <> " Links to headings within the review were reduced to their text, as"
    <> " GitHub gives headings in an issue no anchors."
    <> " The text is otherwise as generated._\n"

-- | A review as a comment for a pull request: the issue body, folded away in
-- a @<details>@ block that shows only the review's title until it is opened.
-- The title moves from the review's first line into the @<summary>@. That is
-- HTML, where GitHub renders no Markdown but still links references, so the
-- title is escaped and made inert as an issue's title is.
--
-- The references are made inert here too. One to the pull request the
-- comment is on would do no harm, but the comment may be posted elsewhere,
-- and the writeups may refer to other issues and users.
commentBody :: Text -> Text -> Text
commentBody title review =
  "<details>\n<summary>" <> htmlEscape (inertTitle title) <> "</summary>\n\n"
    <> T.stripEnd (issueBody (dropTitle review))
    <> "\n\n</details>\n"
  where
    dropTitle r = case T.lines r of
      l : ls | "# " `T.isPrefixOf` l -> T.unlines (dropWhile (T.null . T.strip) ls)
      _ -> r
    htmlEscape = T.concatMap $ \case
      '&' -> "&amp;"
      '<' -> "&lt;"
      '>' -> "&gt;"
      c -> T.singleton c

-- | An issue title is plain text, so the zero-width space goes in as a
-- character where the body has it as an HTML entity.
inertTitle :: Text -> Text
inertTitle = T.concatMap (\c -> if c == '#' || c == '@' then T.pack [c, '\x200B'] else T.singleton c)

-- | Make the references in Markdown text inert, outside fenced code blocks.
inertRefs :: Text -> Text
inertRefs = T.intercalate "\n" . go Nothing . T.splitOn "\n"
  where
    -- The state is the open fence, if any: its character and length.
    go :: Maybe (Char, Int) -> [Text] -> [Text]
    go _ [] = []
    go Nothing (l : ls) = case fenceRun l of
      Just (c, n, _) -> l : go (Just (c, n)) ls
      Nothing -> inertLine l : go Nothing ls
    go open@(Just (c, n)) (l : ls) = case fenceRun l of
      Just (c', n', bare) | c' == c, n' >= n, bare -> l : go Nothing ls
      _ -> l : go open ls
    -- A line that starts with three or more backticks or tildes: the
    -- character, how many, and whether nothing else follows.
    fenceRun l = case T.uncons (T.stripStart l) of
      Just (c, _)
        | c == '`' || c == '~'
        , (run, rest) <- T.span (== c) (T.stripStart l)
        , T.length run >= 3 ->
            Just (c, T.length run, T.null (T.strip rest))
      _ -> Nothing

-- | Make the references in one line of Markdown inert, outside code spans,
-- and reduce links to headings within the page to their text.
inertLine :: Text -> Text
inertLine = T.concat . go ' '
  where
    zwsp = "&#8203;"
    -- @prev@ is the character before the text still to be read.
    go :: Char -> Text -> [Text]
    go prev t = case T.uncons t of
      Nothing -> []
      Just (c, rest)
        | c == '`'
        , (ticks, after) <- T.span (== '`') t ->
            case codeSpan (T.length ticks) after of
              Just (code, rest') -> ticks : code : go '`' rest'
              Nothing -> ticks : go '`' after
        | Just url <- urlAt t
        , rest' <- T.drop (T.length url) t ->
            inertUrl url : go (T.last url) rest'
        | c == '['
        , Just (label, rest') <- inPageLink rest ->
            go prev label <> go ')' rest'
        | c == '#', prev /= '&', startsWith isDigit rest -> "#" : zwsp : go c rest
        | c == '@', not (isAlphaNum prev), startsWith isAlphaNum rest -> "@" : zwsp : go c rest
        | not (isAlphaNum prev)
        , T.toLower (T.take 3 t) == "gh-"
        , startsWith isDigit (T.drop 3 t) ->
            T.take 3 t : zwsp : go '-' (T.drop 3 t)
        | otherwise -> T.singleton c : go c rest
    startsWith f = maybe False (f . fst) . T.uncons
    -- The rest of a code span opened by @k@ backticks, up to and including
    -- the run of exactly @k@ that closes it, and what follows. Nothing if
    -- the line has no such run, in which case the backticks were just text.
    codeSpan :: Int -> Text -> Maybe (Text, Text)
    codeSpan k t =
      let (pre, r) = T.break (== '`') t
          (run, r') = T.span (== '`') r
       in if T.null r
            then Nothing
            else
              if T.length run == k
                then Just (pre <> run, r')
                else (\(code, after) -> (pre <> run <> code, after)) <$> codeSpan k r'
    -- Given what follows a @[@: if it opens a link to a heading in the page,
    -- @[label](#anchor)@, the label and what follows the link. Brackets may
    -- nest in the label, as in a title that names a @Note [...]@.
    inPageLink :: Text -> Maybe (Text, Text)
    inPageLink t = do
      n <- closing (0 :: Int) 0 t
      after <- T.stripPrefix "](#" (T.drop n t)
      let (_, r) = T.break (\c -> c == ')' || isSpace c) after
      r' <- T.stripPrefix ")" r
      pure (T.take n t, r')
    -- The offset of the @]@ that closes a label, skipping escaped
    -- characters.
    closing depth n t = case T.uncons t of
      Nothing -> Nothing
      Just ('\\', r) -> closing depth (n + 2) (T.drop 1 r)
      Just ('[', r) -> closing (depth + 1) (n + 1) r
      Just (']', r)
        | depth == 0 -> Just n
        | otherwise -> closing (depth - 1) (n + 1) r
      Just (_, r) -> closing depth (n + 1) r
    -- A URL runs to the next white space; only its host is ever changed, so
    -- taking in trailing punctuation does no harm.
    urlAt t
      | any (`T.isPrefixOf` t) ["https://", "http://"] = Just (T.takeWhile (not . isSpace) t)
      | otherwise = Nothing
    inertUrl url =
      case [ r
           | scheme <- ["https://", "http://"]
           , www <- ["www.", ""]
           , Just r <- [T.stripPrefix (scheme <> www <> "github.com") url]
           , not (startsWith (\c -> isAlphaNum c || c == '.' || c == '-') r)
           ] of
        r : _ -> "https://redirect.github.com" <> r
        [] -> url

--------------------------------------------------------------------------------
-- Mirror & worktree
--------------------------------------------------------------------------------

-- | What the context pack and the report need to know about a merge request,
-- taken out of the forge's JSON once, so that neither depends on its field
-- names.
data ChangeMeta = ChangeMeta
  { project :: Text
  , ref :: Text
  -- ^ how the forge writes the request's number, e.g. @!16419@
  , title :: Text
  , author :: Text
  , sourceBranch :: Text
  , targetBranch :: Text
  , labels :: [Text]
  , url :: Text
  , description :: Text
  }

data Resolved = Resolved
  { slug :: String
  , worktree :: FilePath
  , baseSha :: Text
  , headSha :: Text
  , mr :: Maybe ChangeMeta
  }

-- | Read a GitLab merge request's API JSON.
gitlabChangeMeta :: Text -> Int -> Value -> ChangeMeta
gitlabChangeMeta project iid v =
  ChangeMeta
    { project
    , ref = "!" <> tshow iid
    , title = fromMaybe "(no title)" (vText "title" v)
    , author = case vKey "author" v of
        Just a -> fromMaybe "?" (vText "name" a) <> maybe "" (\u -> " (@" <> u <> ")") (vText "username" a)
        Nothing -> "?"
    , sourceBranch = fromMaybe "?" (vText "source_branch" v)
    , targetBranch = fromMaybe "?" (vText "target_branch" v)
    , labels = [l | String l <- vArray "labels" v]
    , url =
        fromMaybe
          ("https://gitlab.haskell.org/" <> project <> "/-/merge_requests/" <> tshow iid)
          (vText "web_url" v)
    , description = fromMaybe "" (vText "description" v)
    }

-- | Read a GitHub pull request's API JSON.
githubChangeMeta :: GitHubRepo -> PrNumber -> Value -> ChangeMeta
githubChangeMeta (GitHubRepo repo) (PrNumber n) v =
  ChangeMeta
    { project = repo
    , ref = "#" <> tshow n
    , title = fromMaybe "(no title)" (vText "title" v)
    , author = maybe "?" ("@" <>) (vKey "user" v >>= vText "login")
    , -- head.label is OWNER:BRANCH, which tells a fork's branch from one in
      -- the repository itself.
      sourceBranch = fromMaybe "?" (vKey "head" v >>= vText "label")
    , targetBranch = fromMaybe "?" (vKey "base" v >>= vText "ref")
    , labels = mapMaybe (vText "name") (vArray "labels" v)
    , url =
        fromMaybe
          ("https://github.com/" <> repo <> "/pull/" <> tshow n)
          (vText "html_url" v)
    , description = fromMaybe "" (vText "body" v)
    }

urlEncodeProject :: Text -> String
urlEncodeProject = T.unpack . T.replace "/" "%2F"

projectSlug :: Text -> String
projectSlug = T.unpack . T.replace "/" "-"

-- | Directory of a bare mirror under the data directory.
newtype MirrorDir = MirrorDir FilePath

-- | How a repository is named in progress messages.
newtype RepoLabel = RepoLabel String

-- | URL a repository is cloned from.
newtype CloneUrl = CloneUrl String

-- | Make sure the bare mirror exists, cloning it on first use.
ensureMirror :: MirrorDir -> RepoLabel -> CloneUrl -> IO ()
ensureMirror (MirrorDir mirror) (RepoLabel label) (CloneUrl url) = do
  exists <- doesDirectoryExist mirror
  unless exists $ do
    putStrLn ("One-time setup: mirroring " <> label <> " into " <> mirror <> " ...")
    createDirectoryIfMissing True (takeDirectory mirror)
    inherit "git" ["clone", "--mirror", url, mirror]

ensureRemote :: FilePath -> Text -> IO String
ensureRemote mirror project = do
  let name = projectSlug project
      url = "git@gitlab.haskell.org:" <> T.unpack project <> ".git"
  r <- tryCapture "git" ["-C", mirror, "remote", "get-url", name]
  case r of
    Right _ -> pure ()
    Left _ -> void (capture "git" ["-C", mirror, "remote", "add", name, url])
  pure name

prepareWorktree :: FilePath -> FilePath -> FilePath -> Text -> IO ()
prepareWorktree subStores srcRepo wt headSha = do
  exists <- doesDirectoryExist wt
  if exists
    then do
      dirty <- gitIn wt ["status", "--porcelain"]
      unless (T.null dirty) $
        warn ("worktree " <> wt <> " is dirty; agents are not expected to write to it. Not cleaning up.")
      void (gitIn wt ["checkout", "--detach", T.unpack headSha])
    else do
      createDirectoryIfMissing True (takeDirectory wt)
      void (gitIn srcRepo ["worktree", "prune"])
      gitLoud srcRepo ["worktree", "add", "--detach", wt, T.unpack headSha]
  initSubmodules subStores wt

-- | Remove a worktree after a successful run (~350M each with GHC
-- submodules; recreating one is seconds thanks to the submodule stores).
-- A dirty worktree is kept: agents are not expected to write to it, so
-- unexpected state is preserved for inspection, as in 'prepareWorktree'.
removeWorktree :: FilePath -> IO ()
removeWorktree wt = do
  dirty <- gitIn wt ["status", "--porcelain"]
  if not (T.null dirty)
    then warn ("worktree " <> wt <> " is dirty; not removing it.")
    else do
      commonDir <- gitIn wt ["rev-parse", "--git-common-dir"]
      -- --force: git refuses to remove worktrees containing submodules
      -- without it. Also cleans <commonDir>/worktrees/<name>/ (where the
      -- submodule gitdirs live), which a bare rm -rf would leak.
      r <- tryCapture "git" ["--git-dir=" <> T.unpack commonDir, "worktree", "remove", "--force", wt]
      case r of
        Right _ -> putStrLn ("Removed worktree " <> wt)
        Left e -> warn ("failed to remove worktree " <> wt <> ":\n" <> T.unpack e)

submoduleNames :: FilePath -> IO [String]
submoduleNames wt = do
  out <- gitOut wt ["config", "-f", ".gitmodules", "--get-regexp", "\\.path$"]
  pure
    [ T.unpack n
    | l <- T.lines out
    , let key = T.takeWhile (/= ' ') l
    , Just n <- [T.stripPrefix "submodule." key >>= T.stripSuffix ".path"]
    ]

{- Note [Fast submodule checkout]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A plain `git submodule update --init` in a fresh worktree clones all ~33 GHC
submodules from gitlab.haskell.org — minutes per MR. Instead we keep one
persistent mirror per submodule under <dataDir>/submodules/ (cloned from
upstream once) and point each `submodule.<name>.url` at it via `-c`, so the
checkout clones locally in seconds. The overrides are command-line-only; the
config written by `git submodule init` keeps the canonical URLs.

Stores can lack commits an MR needs (submodule bumps). On failure we fetch
all stores and retry; if that still fails, `git submodule sync` + a plain
update falls back to the canonical remotes. The final sync also resets each
module's origin from the store path back to its canonical URL, so later
incremental updates in a reused worktree fetch from upstream, not the store.
-}
initSubmodules :: FilePath -> FilePath -> IO ()
initSubmodules stores wt = do
  hasModules <- doesFileExist (wt </> ".gitmodules")
  when hasModules $ do
    putStrLn "Initialising submodules ..."
    names <- submoduleNames wt
    void (gitIn wt ["submodule", "init"])
    cfgs <- fmap concat . forM names $ \n -> do
      let store = stores </> n
      storeExists <- doesDirectoryExist store
      unless storeExists $ do
        url <- gitIn wt ["config", "submodule." <> n <> ".url"]
        putStrLn ("One-time setup: mirroring submodule " <> n <> " ...")
        createDirectoryIfMissing True (takeDirectory store)
        inherit "git" ["clone", "--mirror", T.unpack url, store]
      pure ["-c", "submodule." <> n <> ".url=" <> store]
    -- Retries use --force: a failed parallel update can leave submodules
    -- cloned but not checked out, with HEAD already at the pinned commit,
    -- which a plain update skips as up to date.
    let update extra =
          tryCapture "git" $
            ["-C", wt, "-c", "protocol.file.allow=always"]
              <> cfgs
              <> ["submodule", "update", "--init", "--jobs", "4"]
              <> extra
    r <- update [] >>= \case
      Right ok -> pure (Right ok)
      Left _ -> do
        putStrLn "Refreshing submodule stores ..."
        forM_ names $ \n ->
          void (tryCapture "git" ["-C", stores </> n, "fetch", "--prune", "--quiet"])
        update ["--force"]
    case r of
      Right _ -> void (gitIn wt ["submodule", "sync", "--quiet"])
      Left _ -> do
        warn "local submodule stores were insufficient; falling back to canonical remotes"
        void (gitIn wt ["submodule", "sync", "--quiet"])
        gitLoud wt ["submodule", "update", "--init", "--jobs", "4", "--force"]

resolveMr :: FilePath -> Text -> Int -> IO Resolved
resolveMr dataDir project iid = do
  let mirror = dataDir </> "ghc.git"
      enc = urlEncodeProject project
      slug = projectSlug project <> "-mr-" <> show iid
  projMeta <- glabJson ("projects/" <> enc)
  visibility <- reqText "project metadata" "visibility" projMeta
  unless (visibility == "public") $
    die
      ( "project " <> T.unpack project <> " has visibility " <> show visibility
          <> "; GlaHiCo only reviews public projects"
      )
  meta <- glabJson ("projects/" <> enc <> "/merge_requests/" <> show iid)
  targetBranch <- reqText "MR metadata" "target_branch" meta
  -- Every gitlab.haskell.org project shares the ghc/ghc mirror: other
  -- projects are taken to be forks of it and are added as remotes.
  ensureMirror
    (MirrorDir mirror)
    (RepoLabel "ghc/ghc (multiple GB)")
    (CloneUrl "git@gitlab.haskell.org:ghc/ghc.git")
  remote <- if project == "ghc/ghc" then pure "origin" else ensureRemote mirror project
  -- GitLab prunes the head ref of closed and merged MRs after a while, but
  -- keeps the head commit fetchable by SHA.
  let mrRef = "refs/merge-requests/" <> show iid <> "/head"
  advertised <- gitIn mirror ["ls-remote", remote, mrRef]
  headSrc <- case vText "sha" meta of
    _ | not (T.null advertised) -> pure mrRef
    Just sha -> do
      warn
        ( "!" <> show iid <> " has no head ref on the remote (GitLab prunes them for closed and merged MRs);"
            <> " fetching its last head "
            <> T.unpack sha
            <> " instead"
        )
      pure (T.unpack sha)
    Nothing -> die ("!" <> show iid <> " has no head ref on the remote, and the MR metadata has no sha")
  putStrLn ("Fetching !" <> show iid <> " from " <> T.unpack project <> " ...")
  gitLoud
    mirror
    [ "fetch"
    , remote
    , "+" <> headSrc <> ":refs/glahico/" <> slug
    , "+refs/heads/" <> T.unpack targetBranch <> ":refs/glahico/" <> slug <> "-base"
    ]
  headSha <- gitIn mirror ["rev-parse", "refs/glahico/" <> slug]
  case vText "sha" meta of
    Just apiSha
      | apiSha /= headSha ->
          warn
            ( "fetched MR head " <> T.unpack headSha <> " differs from API sha " <> T.unpack apiSha
                <> " (the MR may have been updated mid-run)"
            )
    _ -> pure ()
  baseSha <- gitIn mirror ["merge-base", "refs/glahico/" <> slug, "refs/glahico/" <> slug <> "-base"]
  let wt = dataDir </> "wt" </> slug
  prepareWorktree (dataDir </> "submodules") mirror wt headSha
  pure Resolved {slug, worktree = wt, baseSha, headSha, mr = Just (gitlabChangeMeta project iid meta)}

-- | Resolve a GitHub pull request to a worktree at its head. Each repository
-- gets a mirror and submodule stores of its own, cloned over HTTPS since
-- only public repositories are reviewed.
resolvePr :: FilePath -> GitHubRepo -> PrNumber -> IO Resolved
resolvePr dataDir ghRepo@(GitHubRepo repo) prNumber@(PrNumber n) = do
  let repoDir = dataDir </> "mirrors" </> "github.com" </> T.unpack repo
      mirror = repoDir <> ".git"
      slug = projectSlug repo <> "-pr-" <> show n
  repoMeta <- ghJson ("repos/" <> T.unpack repo)
  visibility <- reqText "repository metadata" "visibility" repoMeta
  unless (visibility == "public") $
    die
      ( "repository " <> T.unpack repo <> " has visibility " <> show visibility
          <> "; GlaHiCo only reviews public repositories"
      )
  pr <- ghJson ("repos/" <> T.unpack repo <> "/pulls/" <> show n)
  baseBranch <-
    maybe (die "pull request metadata: missing field base.ref") pure (vKey "base" pr >>= vText "ref")
  ensureMirror
    (MirrorDir mirror)
    (RepoLabel (T.unpack repo))
    (CloneUrl ("https://github.com/" <> T.unpack repo <> ".git"))
  putStrLn ("Fetching #" <> show n <> " from " <> T.unpack repo <> " ...")
  -- Unlike GitLab, GitHub keeps refs/pull/N/head after a pull request is
  -- closed or merged, so there is no fallback to the API's head SHA.
  gitLoud
    mirror
    [ "fetch"
    , "origin"
    , "+refs/pull/" <> show n <> "/head:refs/glahico/" <> slug
    , "+refs/heads/" <> T.unpack baseBranch <> ":refs/glahico/" <> slug <> "-base"
    ]
  headSha <- gitIn mirror ["rev-parse", "refs/glahico/" <> slug]
  case vKey "head" pr >>= vText "sha" of
    Just apiSha
      | apiSha /= headSha ->
          warn
            ( "fetched pull request head " <> T.unpack headSha <> " differs from API sha " <> T.unpack apiSha
                <> " (the pull request may have been updated mid-run)"
            )
    _ -> pure ()
  tipBase <- gitIn mirror ["merge-base", "refs/glahico/" <> slug, "refs/glahico/" <> slug <> "-base"]
  -- Once a pull request has been merged without squashing or rebasing, its
  -- head is on the base branch and the merge base is the head itself, which
  -- would make the diff empty. The API still has the base the pull request
  -- was opened against.
  baseSha <- case vKey "base" pr >>= vText "sha" of
    Just apiBase | tipBase == headSha -> do
      warn
        ( "#" <> show n <> " is already contained in " <> T.unpack baseBranch
            <> "; diffing against the base recorded by GitHub, " <> T.unpack apiBase
        )
      gitIn mirror ["merge-base", "refs/glahico/" <> slug, T.unpack apiBase]
    _ -> pure tipBase
  let wt = dataDir </> "wt" </> slug
  prepareWorktree (repoDir <> ".submodules") mirror wt headSha
  pure Resolved {slug, worktree = wt, baseSha, headSha, mr = Just (githubChangeMeta ghRepo prNumber pr)}

-- | rev-parse a spec; if unknown locally, try fetching it from the repo's
-- remotes (direct-SHA fetch for full hashes, plain fetch otherwise) and retry.
resolveRev :: FilePath -> Text -> IO Text
resolveRev repo spec = do
  let revParse = tryCapture "git" ["-C", repo, "rev-parse", "--verify", T.unpack spec <> "^{commit}"]
  revParse >>= \case
    Right sha -> pure (T.strip (lbsText sha))
    Left e -> do
      remotes <- T.words <$> gitIn repo ["remote"]
      when (null remotes) $
        die ("git rev-parse " <> T.unpack spec <> " failed:\n" <> T.unpack e)
      putStrLn ("Rev " <> T.unpack spec <> " not found locally; fetching from remotes ...")
      -- Servers only accept direct fetches of full SHAs, so strip any
      -- ^/~ suffix (the base spec of a single-commit target is <sha>^).
      let bare = T.takeWhile (\c -> c /= '^' && c /= '~') spec
          isSha = T.length bare == 40 && T.all isHexDigit bare
          fetch args = either (const False) (const True) <$> tryCapture "git" (["-C", repo, "fetch"] <> args)
      gotSha <-
        if isSha
          then anyM (\r -> fetch [T.unpack r, T.unpack bare]) remotes
          else pure False
      unless gotSha $
        mapM_ (\r -> fetch [T.unpack r]) remotes
      gitIn repo ["rev-parse", "--verify", T.unpack spec <> "^{commit}"]
  where
    anyM f = foldr (\x rest -> f x >>= \ok -> if ok then pure True else rest) (pure False)

resolveLocal :: FilePath -> Text -> Text -> IO Resolved
resolveLocal dataDir baseSpec headSpec = do
  repoTop <- T.strip . lbsText <$> capture "git" ["rev-parse", "--show-toplevel"]
  let repo = T.unpack repoTop
  headSha <- resolveRev repo headSpec
  baseTip <- resolveRev repo baseSpec -- head first: one fetch covers <sha>^ too
  baseSha <- gitIn repo ["merge-base", T.unpack baseTip, T.unpack headSha]
  let slug =
        "local-" <> takeFileName repo <> "-"
          <> T.unpack (T.take 7 baseSha) <> ".." <> T.unpack (T.take 7 headSha)
      wt = dataDir </> "wt" </> slug
  prepareWorktree (dataDir </> "submodules") repo wt headSha
  pure Resolved {slug, worktree = wt, baseSha, headSha, mr = Nothing}

--------------------------------------------------------------------------------
-- Context pack
--------------------------------------------------------------------------------

-- | Truncate at a line boundary within the byte cap, marking the cut in the
-- content and reporting it for the disclosure header.
capBytes :: Text -> Int -> Text -> (Text, Maybe Text)
capBytes name cap content
  | BS.length bs <= cap = (content, Nothing)
  | otherwise = (capped, Just (name <> " truncated at " <> tshow cap <> " bytes"))
  where
    bs = TE.encodeUtf8 content
    cut = BS.take cap bs
    atNewline = maybe cut (`BS.take` cut) (BS.elemIndexEnd 0x0a cut)
    capped =
      TE.decodeUtf8Lenient atNewline
        <> "\n[truncated: " <> name <> " exceeded " <> tshow cap <> " bytes]\n"

mrMarkdown :: ChangeMeta -> Text
mrMarkdown md =
  T.unlines
    [ "# " <> md.title <> " (" <> md.ref <> ")"
    , ""
    , "- Project: " <> md.project
    , "- Author: " <> md.author
    , "- Branches: " <> md.sourceBranch <> " → " <> md.targetBranch
    , "- Labels: " <> (if null md.labels then "(none)" else T.intercalate ", " md.labels)
    , "- URL: " <> md.url
    , ""
    , "## Description"
    , ""
    , md.description
    ]

buildContext :: Resolved -> FilePath -> IO (FilePath, [Text])
buildContext res runDir = do
  let ctx = runDir </> "context"
      range = T.unpack res.baseSha <> ".." <> T.unpack res.headSha
  createDirectoryIfMissing True ctx
  truncsRef <- newIORef []
  let putCapped :: FilePath -> Text -> Int -> Text -> IO ()
      putCapped path name cap content = do
        let (content', mnote) = capBytes name cap content
        forM_ mnote (\note -> modifyIORef' truncsRef (++ [note]))
        TIO.writeFile path content'
  diff <- gitOut res.worktree ["diff", range]
  putCapped (ctx </> "diff.patch") "diff.patch" (400 * 1024) diff
  stat <- gitOut res.worktree ["diff", "--stat", range]
  putCapped (ctx </> "diffstat.txt") "diffstat.txt" (32 * 1024) stat
  commits <- gitOut res.worktree ["log", "--reverse", range]
  putCapped (ctx </> "commits.txt") "commits.txt" (100 * 1024) commits
  forM_ res.mr $ \md ->
    putCapped (ctx </> "mr.md") "mr.md" (50 * 1024) (mrMarkdown md)
  truncs <- readIORef truncsRef
  pure (ctx, truncs)

--------------------------------------------------------------------------------
-- Prompt loading & JSON schemas
--------------------------------------------------------------------------------

-- Cabal resolves the script to an absolute path before compiling, so __FILE__
-- locates the checkout this binary was built from (prompts/, git metadata).
scriptDir :: FilePath
scriptDir = takeDirectory __FILE__

-- | The words in the prompts that depend on which project is under review
-- and on which forge. Each field fills the placeholder named beside it.
data Wording = Wording
  { projectName :: Text
  -- ^ @{project}@
  , projectIntro :: Text
  -- ^ @{project_intro}@: the name as first introduced to the finder
  , invariantsHint :: Text
  -- ^ @{invariants_hint}@: ends the verifier's sentence about looking for
  -- invariants, so it carries that sentence's full stop
  , requestWord :: Text
  -- ^ @{request}@: what the forge calls a request to merge
  }

-- | The wording GHC reviews have always had. The hint's line break and
-- indentation are part of the verifier prompt's layout.
ghcWording :: Wording
ghcWording =
  Wording
    { projectName = "GHC"
    , projectIntro = "GHC, the Glasgow Haskell Compiler"
    , invariantsHint =
        " — GHC documents\n   many invariants in `Note [...]` comments; check the relevant ones."
    , requestWord = "MR"
    }

-- | Merge requests and local ranges are taken to be GHC, as before. A pull
-- request is worded for its repository, with no hints: those are to be
-- written from what real reviews get wrong, not guessed at.
wordingFor :: Target -> Wording
wordingFor = \case
  PrTarget (GitHubRepo "haskell/cabal") _ ->
    pullRequest "Cabal" "Cabal, the Haskell build system (the Cabal library and the cabal-install tool)"
  PrTarget (GitHubRepo repo) _ -> pullRequest repo repo
  _ -> ghcWording
  where
    pullRequest projectName projectIntro =
      Wording {projectName, projectIntro, invariantsHint = ".", requestWord = "PR"}

loadPrompt :: Wording -> FilePath -> Bool -> IO Text
loadPrompt w name isMr = do
  let path = scriptDir </> "prompts" </> name
  ok <- doesFileExist path
  unless ok (die ("prompt file not found: " <> path))
  raw <- TIO.readFile path
  pure $
    fill $
      if isMr
        then raw
        else T.unlines (filter (not . ("[MR targets only]" `T.isInfixOf`)) (T.lines raw))
  where
    fill =
      T.replace "{request}" w.requestWord
        . T.replace "{invariants_hint}" w.invariantsHint
        . T.replace "{project}" w.projectName
        . T.replace "{project_intro}" w.projectIntro

renderFinderPrompt :: Wording -> FilePath -> Bool -> Maybe Text -> IO Text
renderFinderPrompt w ctxDir isMr adhocText = do
  raw <- loadPrompt w "finder.md" isMr
  let p = T.replace "{ctx}" (T.pack ctxDir) raw
  pure $ case adhocText of
    Nothing -> p
    Just extra -> p <> "\n## Additional instructions for this run\n\n" <> extra <> "\n"

renderVerifierPrompt :: Wording -> FilePath -> Bool -> Finding -> IO Text
renderVerifierPrompt w ctxDir isMr f = do
  raw <- loadPrompt w "verifier.md" isMr
  pure (T.replace "{finding}" (lbsText (AP.encodePretty f)) (T.replace "{ctx}" (T.pack ctxDir) raw))

jstr :: Text -> Value
jstr = String

finderSchema :: Value
finderSchema =
  object
    [ "type" .= jstr "object"
    , "additionalProperties" .= False
    , "required" .= [jstr "findings"]
    , "properties"
        .= object
          [ "findings"
              .= object
                [ "type" .= jstr "array"
                , "items"
                    .= object
                      [ "type" .= jstr "object"
                      , "additionalProperties" .= False
                      , "required" .= map jstr ["id", "title", "file", "line", "claim", "evidence"]
                      , "properties"
                          .= object
                            [ "id" .= tobj "string"
                            , "title" .= tobj "string"
                            , "file" .= tobj "string"
                            , "line" .= tobj "integer"
                            , "claim" .= tobj "string"
                            , "evidence" .= tobj "string"
                            ]
                      ]
                ]
          ]
    ]
  where
    tobj t = object ["type" .= jstr t]

verifierSchema :: Value
verifierSchema =
  object
    [ "type" .= jstr "object"
    , "additionalProperties" .= False
    , "required" .= map jstr ["verdict", "relevant", "disprove_evidence", "prove_evidence", "relevance_rationale", "title", "writeup", "snippets"]
    , "properties"
        .= object
          [ "verdict" .= object ["type" .= jstr "string", "enum" .= map jstr ["confirmed", "uncertain", "refuted"]]
          , "relevant" .= object ["type" .= jstr "boolean"]
          , "disprove_evidence" .= object ["type" .= jstr "string"]
          , "prove_evidence" .= object ["type" .= jstr "string"]
          , "relevance_rationale" .= object ["type" .= jstr "string"]
          , "title" .= object ["type" .= jstr "string"]
          , "writeup" .= object ["type" .= jstr "string"]
          , "snippets"
              .= object
                [ "type" .= jstr "array"
                , "items"
                    .= object
                      [ "type" .= jstr "object"
                      , "additionalProperties" .= False
                      , "required" .= map jstr ["file", "first_line", "last_line", "key_line"]
                      , "properties"
                          .= object
                            [ "file" .= object ["type" .= jstr "string"]
                            , "first_line" .= object ["type" .= jstr "integer"]
                            , "last_line" .= object ["type" .= jstr "integer"]
                            , "key_line" .= object ["type" .= jstr "integer"]
                            ]
                      ]
                ]
          ]
    ]

--------------------------------------------------------------------------------
-- Findings & verdicts
--------------------------------------------------------------------------------

data Finding = Finding
  { id :: Text
  , title :: Text
  , file :: Text
  , line :: Int
  , claim :: Text
  , evidence :: Text
  }
  deriving (Generic, Show)

instance FromJSON Finding

instance ToJSON Finding

newtype Findings = Findings {findings :: [Finding]}
  deriving (Generic, Show)

instance FromJSON Findings

instance ToJSON Findings

-- | A line range the verifier wants shown to the reader; the report quotes
-- the range from the head checkout rather than trusting model-quoted code.
-- @key_line@ is the core spot within the range, marked with an arrow comment.
data Snippet = Snippet
  { file :: Text
  , first_line :: Int
  , last_line :: Int
  , key_line :: Int
  }
  deriving (Generic, Show)

instance FromJSON Snippet

instance ToJSON Snippet

data Verdict = Verdict
  { verdict :: Text
  , relevant :: Bool
  , disprove_evidence :: Text
  , prove_evidence :: Text
  , relevance_rationale :: Text
  , title :: Text
  , writeup :: Text
  , snippets :: [Snippet]
  }
  deriving (Generic, Show)

instance FromJSON Verdict

instance ToJSON Verdict

-- The verifier's title wins: it knows what was actually established, and the
-- finder's title is a pre-verification hypothesis.
findingHeading :: Finding -> Verdict -> Text
findingHeading f v = f.id <> ": " <> (if T.null title then f.title else title)
  where
    title = T.strip v.title

embedFinding :: Finding -> Verdict -> Value
embedFinding f v = case toJSON v of
  Object o -> Object (KM.insert "finding" (toJSON f) o)
  x -> x

decodeStructured :: FromJSON a => String -> FilePath -> Value -> IO a
decodeStructured what envelopePath v = case A.fromJSON v of
  A.Success x -> pure x
  A.Error e ->
    die
      ( what <> ": structured output does not match the expected shape: " <> e
          <> "\nraw envelope preserved at: " <> envelopePath
      )

--------------------------------------------------------------------------------
-- runClaude
--------------------------------------------------------------------------------

-- | Token counts for one model within one claude call (or summed over calls).
data ModelTokens = ModelTokens
  { input :: Int
  , cacheCreation :: Int
  , cacheRead :: Int
  , output :: Int
  }

addTokens :: ModelTokens -> ModelTokens -> ModelTokens
addTokens a b =
  ModelTokens
    { input = a.input + b.input
    , cacheCreation = a.cacheCreation + b.cacheCreation
    , cacheRead = a.cacheRead + b.cacheRead
    , output = a.output + b.output
    }

-- | Sum per-call usage lists into one per-model list (first-seen model order).
sumUsage :: [[(Text, ModelTokens)]] -> [(Text, ModelTokens)]
sumUsage uss =
  [ (m, foldr1 addTokens [t | (m', t) <- pairs, m' == m])
  | m <- nub (map fst pairs)
  ]
  where
    pairs = concat uss

data ClaudeRun = ClaudeRun
  { structured :: Value
  , usage :: [(Text, ModelTokens)]
  , finalContext :: Maybe Int
  , cost :: Maybe Usd -- Nothing when the envelope has no total_cost_usd
  }

-- | A cost in US dollars at Claude API prices, as claude reports it for a
-- call. On a subscription nothing is billed; the figure is what the same
-- tokens would have cost through the API.
newtype Usd = Usd Double

instance Semigroup Usd where
  Usd a <> Usd b = Usd (a + b)

instance Monoid Usd where
  mempty = Usd 0

showUsd :: Usd -> String
showUsd (Usd d) = printf "$%.2f" d

-- | One line for the terminal giving the cost of a run. It covers every
-- model claude used, the harness's auxiliary haiku calls included, so it can
-- be a little more than the models named in the disclosure account for.
costLine :: Maybe Usd -> [Maybe Usd] -> String
costLine finder verifiers =
  "Cost: " <> showUsd (mconcat (catMaybes (finder : verifiers))) <> " in Claude API terms (finder "
    <> maybe "unknown" showUsd finder
    <> verifierPart
    <> ")"
    <> missingPart
  where
    n = length verifiers
    verifierPart
      | n == 0 = ""
      | otherwise =
          ", " <> show n <> " verifier call" <> (if n == 1 then "" else "s") <> " "
            <> showUsd (mconcat (catMaybes verifiers))
    missing = length (filter (not . isJust) (finder : verifiers))
    missingPart
      | missing == 0 = ""
      | otherwise = "; " <> show missing <> " call(s) reported no cost"

allowedGitTools :: [String]
allowedGitTools =
  [ "Bash(git log:*)"
  , "Bash(git show:*)"
  , "Bash(git diff:*)"
  , "Bash(git grep:*)"
  , "Bash(git blame:*)"
  , "Bash(git cat-file:*)"
  , "Bash(git rev-parse:*)"
  , "Bash(git merge-base:*)"
  ]

runClaude :: FilePath -> FilePath -> FilePath -> String -> String -> Value -> Text -> IO ClaudeRun
runClaude wt ctxDir envelopePath model effort schema prompt = do
  hostEnv <- getEnvironment
  let argv =
        [ "-p"
        , T.unpack prompt
        , "--model"
        , model
        , "--effort"
        , effort
        , "--output-format"
        , "json"
        , "--json-schema"
        , T.unpack (lbsText (A.encode schema))
        , "--tools"
        , "Read,Glob,Grep,Bash"
        , "--allowedTools"
        , intercalate "," allowedGitTools
        , "--add-dir" -- context/ lives outside the worktree; without this, dontAsk denies the reads
        , ctxDir
        , "--permission-mode"
        , "dontAsk"
        , "--setting-sources"
        , ""
        , "--disable-slash-commands"
        , "--strict-mcp-config"
        , "--no-session-persistence"
        ]
      -- CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC makes claude omit
      -- usage.iterations, losing the final-context estimate.
      env' =
        ("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1")
          : filter
              ( (`notElem` ["CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
                  . fst
              )
              hostEnv
      replay = "replay: (cd " <> shellQuote wt <> " && " <> unwords (map shellQuote ("claude" : argv)) <> ")"
      failWith msg = die (msg <> "\nraw output preserved at: " <> envelopePath <> "\n" <> replay)
  (ec, out, errOut) <-
    readProcess (setStdin nullStream (setWorkingDir wt (setEnv env' (proc "claude" argv))))
  BL.writeFile envelopePath out
  case ec of
    ExitFailure n -> failWith ("claude exited with code " <> show n <> ":\n" <> T.unpack (lbsText errOut))
    ExitSuccess -> pure ()
  v <- either (\e -> failWith ("cannot parse claude output as JSON: " <> e)) pure (eitherDecode out)
  unless
    ( vText "type" v == Just "result"
        && vText "subtype" v == Just "success"
        && vBoolIs "is_error" False v
    )
    (failWith "claude result envelope does not indicate success")
  structured <- case vKey "structured_output" v of
    Just s | s /= Null -> pure s
    _ -> failWith "claude result envelope has no structured_output"
  let i k mv = fromMaybe 0 (vInt k mv)
      usage = case vKey "modelUsage" v of
        Just (Object o) ->
          [ ( Key.toText k
            , ModelTokens
                { input = i "inputTokens" mv
                , cacheCreation = i "cacheCreationInputTokens" mv
                , cacheRead = i "cacheReadInputTokens" mv
                , output = i "outputTokens" mv
                }
            )
          | (k, mv) <- KM.toList o
          ]
        _ -> []
      -- The last request's input + cache tokens approximate the final context
      -- size. When iterations are absent (e.g. under
      -- CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1) there is no per-request
      -- data — the top-level usage is cumulative — so report no estimate.
      finalContext = do
        u <- vKey "usage" v
        src <- case vArray "iterations" u of
          [] -> Nothing
          its -> Just (last its)
        case mapMaybe (`vInt` src) ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] of
          [] -> Nothing
          xs -> Just (sum xs)
      cost = case vKey "total_cost_usd" v of
        Just (Number n) -> Just (Usd (realToFrac n))
        _ -> Nothing
  pure ClaudeRun {structured, usage, finalContext, cost}

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

data Stage = Stage
  { alias :: String
  , effortLevel :: String
  , ranUsage :: [(Text, ModelTokens)]
  , finalContexts :: [Int] -- one entry per claude call in this stage
  }

-- | The harness makes auxiliary calls with haiku; the disclosure omits those
-- unless haiku itself was requested. If filtering would empty a non-empty
-- list, keep it unfiltered rather than claiming the stage ran no calls.
disclosedUsage :: String -> [(Text, ModelTokens)] -> [(Text, ModelTokens)]
disclosedUsage alias us
  | "haiku" `isInfixOf` alias = us
  | null filtered = us
  | otherwise = filtered
  where
    filtered = [u | u@(m, _) <- us, not ("haiku" `T.isInfixOf` m)]

-- | A snippet as it appears in the review: label, fence info string, the
-- label as a comment line in the file's language (Nothing when we don't know
-- its comment syntax), and the quoted text (Nothing when the range couldn't
-- be resolved in the worktree).
data RenderedSnippet = RenderedSnippet
  { label :: Text
  , lang :: Text
  , commentedLabel :: Maybe Text
  , body :: Maybe Text
  }

snippetCap :: Int
snippetCap = 50

-- | Quote a snippet range from the head worktree. The range is model output,
-- so a bad path or empty range degrades to an "unavailable" marker instead of
-- failing the run; ranges are clamped to the file and capped at 'snippetCap'.
extractSnippet :: FilePath -> Snippet -> IO RenderedSnippet
extractSnippet worktree s = do
  let label = s.file <> ":" <> tshow s.first_line <> "-" <> tshow s.last_line
      path = worktree </> T.unpack s.file
      -- .T files are the Python testsuite driver files. Only file types
      -- with a trailing-comment syntax get a prefix; RST and Markdown
      -- have none, and .stdout/.stderr are opaque.
      ext = takeExtension (T.unpack s.file)
      isMakefile = takeFileName (T.unpack s.file) == "Makefile"
      lang
        | ext `elem` [".hs", ".lhs", ".hs-boot", ".hsc", ".hsig", ".bkp", ".script"] = "haskell"
        | ext == ".cabal" = "cabal"
        | ext `elem` [".c", ".h", ".cmm"] = "c"
        | ext == ".js" = "javascript"
        | ext `elem` [".py", ".T"] = "python"
        | ext == ".sh" = "bash"
        | ext `elem` [".yaml", ".yml"] = "yaml"
        | ext == ".tex" = "latex"
        | ext == ".rst" = "rst"
        | ext == ".md" = "markdown"
        | isMakefile = "makefile"
        | otherwise = ""
      commentPrefix
        | lang `elem` ["haskell", "cabal"] = Just "-- "
        | lang `elem` ["c", "javascript"] = Just "// "
        | lang `elem` ["python", "bash", "yaml", "makefile"] = Just "# "
        | lang == "latex" = Just "% "
        | otherwise = Nothing
      commentedLabel = (<> label) <$> commentPrefix
  exists <- doesFileExist path
  body <-
    if not exists
      then pure Nothing
      else do
        ls <- T.lines . TE.decodeUtf8Lenient <$> BS.readFile path
        let lo = max 1 s.first_line
            wanted = s.last_line - lo + 1
            picked = take (min snippetCap wanted) (drop (lo - 1) ls)
            truncated = wanted > snippetCap && length picked == snippetCap
            -- Arrow marker on the key line, as a comment when we know the
            -- language's syntax and bare otherwise.
            marker = maybe "" (\p -> T.strip p <> " ") commentPrefix <> "<========== HERE"
            marked =
              [ if n == s.key_line then l <> "  " <> marker else l
              | (n, l) <- zip [lo ..] picked
              ]
        pure $
          if null picked
            then Nothing
            else Just (T.unlines (marked ++ ["[snippet truncated]" | truncated]))
  pure RenderedSnippet {label, lang, commentedLabel, body}

data Report = Report
  { targetDesc :: Text
  , titleSuffix :: Text
  , baseSha :: Text
  , headSha :: Text
  , commit :: Text
  , finderStage :: Stage
  , verifierStage :: Stage
  , truncations :: [Text]
  , totalFindings :: Int
  , unverified :: Int
  , verified :: [(Finding, Verdict, [RenderedSnippet])]
  , adhocPrompt :: Maybe Text
  , uncommittedPrompts :: [(String, Text)]
  }

-- GitLab/GitHub heading anchor: lowercase, drop everything that isn't
-- alphanumeric, space, hyphen or underscore, then spaces become hyphens.
headingAnchor :: Text -> Text
headingAnchor =
  T.map (\c -> if c == ' ' then '-' else c)
    . T.filter (\c -> isAlphaNum c || c `elem` (" -_" :: String))
    . T.map toLower

-- Long enough that no backtick run in the body can close the fence early.
fenceFor :: Text -> Text
fenceFor body = T.replicate (max 4 (longest + 1)) "`"
  where
    longest = maximum (0 : [T.length g | g <- T.group body, T.head g == '`'])

renderReview :: Report -> Text
renderReview r =
  T.unlines
    ( headerLines ++ feedbackLines ++ findingsSection ++ lowSection ++ lowRelSection ++ adhocSection
        ++ dirtySection ++ disclosureSection ++ disclaimerLines
    )
  where
    confirmedRel = [fv | fv@(_, v, _) <- r.verified, v.verdict == "confirmed", v.relevant]
    uncertainRel = [fv | fv@(_, v, _) <- r.verified, v.verdict == "uncertain", v.relevant]
    lowRel = [fv | fv@(_, v, _) <- r.verified, not v.relevant, v.verdict /= "refuted"]
    backticked t = "`" <> t <> "`"
    stageLine name (st :: Stage) =
      "- " <> name <> ": requested " <> backticked (T.pack st.alias)
        <> " at effort " <> backticked (T.pack st.effortLevel) <> "; ran "
        <> ranPart st.ranUsage
        <> contextPart st.finalContexts
    ranPart [] = "no calls"
    ranPart us = T.intercalate ", " [backticked m <> " (" <> tokensText t <> ")" | (m, t) <- us]
    tokensText (t :: ModelTokens) =
      commaSep (t.input + t.cacheCreation + t.cacheRead) <> " tokens in ("
        <> commaSep t.cacheRead <> " cache reads), " <> commaSep t.output <> " out"
    contextPart [] = ""
    contextPart [c] = "; final context ≈" <> commaSep c <> " tokens"
    contextPart cs =
      "; final context ≈" <> commaSep (maximum cs) <> " tokens max across "
        <> tshow (length cs) <> " calls"
    findingsLine
      | r.totalFindings == 0 = "none reported by the finder"
      | otherwise =
          tshow r.totalFindings <> " reported by the finder; "
            <> T.intercalate "; " (outcomeParts ++ unverifiedParts)
    outcomeParts =
      [tshow (length confirmedRel) <> " high-confidence" | not (null confirmedRel)]
        ++ [ tshow (length uncertainRel) <> " uncertain but judged relevant (included as low-confidence)"
           | not (null uncertainRel)
           ]
        ++ [ tshow (length lowRel) <> " judged low-relevance (included)"
           | not (null lowRel)
           ]
        ++ [ tshow (length droppedFvs) <> " dropped ("
               <> T.intercalate ", " [f.id <> ": refuted" | (f, _) <- droppedFvs]
               <> ")"
           | not (null droppedFvs)
           ]
    unverifiedParts =
      [ tshow r.unverified <> " not verified (preserved in findings.json in the run directory)"
      | r.unverified > 0
      ]
    droppedFvs = [(f, v) | (f, v, _) <- r.verified, v.verdict == "refuted"]
    block extraLines (f, v, snips) =
      [ "### " <> findingHeading f v
      , ""
      ]
        ++ concatMap snippetLines snips
        ++ [ v.writeup
           , ""
           ]
        ++ extraLines v
    -- Fences are sized via fenceFor so the body can't break out. The location
    -- goes inside the fence as a comment when we know the language's comment
    -- syntax; a label line above is the fallback.
    snippetLines (s :: RenderedSnippet) = case s.body of
      Nothing -> [backticked s.label, "", "_snippet unavailable_", ""]
      Just b ->
        let body = T.stripEnd b
            fence = fenceFor body
         in case s.commentedLabel of
              Just c -> [fence <> s.lang, c, body, fence, ""]
              Nothing -> [backticked s.label, "", fence <> s.lang, body, fence, ""]
    headerLines = ["# GlaHiCo review: " <> r.titleSuffix, ""] ++ summaryLines
    feedbackLines =
      [ "_Your feedback can help to make this service better! A quick reply"
          <> " like `f1: noise, f2: false positive` helps, and so does"
          <> " pointing out anything the review missed._"
      , ""
      ]
    summaryLines
      | null confirmedRel && null uncertainRel && null lowRel =
          [ if r.totalFindings == 0
              then "_The finder reported no findings._"
              else "_No findings survived verification._"
          , ""
          ]
      | otherwise =
          linkGroup "High-confidence findings:" confirmedRel
            ++ linkGroup "Low-confidence findings:" uncertainRel
            ++ linkGroup "Low-relevance findings:" lowRel
    linkGroup label fvs
      | null fvs = []
      | otherwise =
          label
            : ""
            : [ "- [" <> heading <> "](#" <> headingAnchor heading <> ")"
              | (f, v, _) <- fvs
              , let heading = findingHeading f v
              ]
            ++ [""]
    findingsSection
      | null confirmedRel = []
      | otherwise =
          "## High-confidence findings" : "" : concatMap (block (const [])) confirmedRel
    disclosureSection =
      [ "## Disclosure"
      , ""
      , "- GlaHiCo commit: " <> backticked r.commit <> " (the prompts are part of the repository at this commit)"
      , "- Target: " <> r.targetDesc
      , "- Base: " <> backticked r.baseSha
      , "- Head: " <> backticked r.headSha
      , stageLine "Finder" r.finderStage
      , stageLine "Verifier" r.verifierStage
      , "- Truncations: " <> (if null r.truncations then "none" else T.intercalate "; " r.truncations)
      , "- Findings: " <> findingsLine
      , ""
      ]
    lowSection
      | null uncertainRel = []
      | otherwise =
          [ "## Low-confidence findings"
          , ""
          , "The verifier could neither confirm nor refute these; they are included"
          , "because it judged them relevant."
          , ""
          ]
            ++ concatMap (block (const [])) uncertainRel
    lowRelSection
      | null lowRel = []
      | otherwise =
          [ "## Low-relevance findings"
          , ""
          , "The verifier judged these findings valid or plausible, but of low"
          , "relevance for this change."
          , ""
          ]
            ++ concatMap (block rationaleLines) lowRel
    rationaleLines (v :: Verdict) =
      [ "_Verdict: " <> v.verdict <> "; judged low relevance: "
          <> T.stripEnd v.relevance_rationale <> "_"
      , ""
      ]
    adhocSection = case r.adhocPrompt of
      Nothing -> []
      Just t ->
        let body = T.stripEnd t
            fence = fenceFor body
         in [ "## Appendix: ad-hoc prompt additions"
            , ""
            , "The following instructions were appended to the finder prompt for this run:"
            , ""
            , fence
            , body
            , fence
            , ""
            ]
    disclaimerLines =
      [ "> **This is tool output**, produced by GlaHiCo, an LLM review pipeline, and"
      , "> posted verbatim. Findings were filtered mechanically by the pipeline's"
      , "> verifier stage; no human curated the output. The Claude Code harness"
      , "> prepends a system prompt of its own that this disclosure cannot reproduce —"
      , "> the disclosure covers what GlaHiCo sent — and some host state (account"
      , "> authentication, `~/.claude.json`) also remains active in the harness."
      ]
    dirtySection = case r.uncommittedPrompts of
      [] -> []
      ps ->
        [ "## Appendix: uncommitted prompts"
        , ""
        , "These prompt files differed from the GlaHiCo commit above; their exact"
        , "content as used in this run:"
        , ""
        ]
          ++ concatMap
            ( \(name, content) ->
                let body = T.stripEnd content
                    fence = fenceFor body
                 in ["### " <> T.pack name, "", fence, body, fence, ""]
            )
            ps

glahicoCommit :: IO Text
glahicoCommit = do
  r <- tryCapture "git" ["-C", scriptDir, "rev-parse", "HEAD"]
  case r of
    Left _ -> pure "unknown"
    Right out -> do
      let sha = T.strip (lbsText out)
      dirty <- tryCapture "git" ["-C", scriptDir, "status", "--porcelain"]
      pure $ case dirty of
        Right d | T.null (T.strip (lbsText d)) -> sha
        _ -> sha <> "-dirty"

-- | Prompts whose content at runtime differs from the glahico commit (dirty or
-- untracked): disclosed by value in the report, like ad-hoc prompts.
uncommittedPromptFiles :: IO [(String, Text)]
uncommittedPromptFiles =
  fmap catMaybes . forM ["finder.md", "verifier.md"] $ \name -> do
    let rel = "prompts/" <> name
        path = scriptDir </> rel
    tracked <- tryCapture "git" ["-C", scriptDir, "ls-files", "--error-unmatch", rel]
    changed <- case tracked of
      Left _ -> pure True
      Right _ -> do
        d <- tryCapture "git" ["-C", scriptDir, "diff", "HEAD", "--", rel]
        pure $ case d of
          Right out -> not (T.null (T.strip (lbsText out)))
          Left _ -> True
    if changed
      then do
        content <- TIO.readFile path
        pure (Just (rel, content))
      else pure Nothing

--------------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------------

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  cmd <-
    execParser
      ( info
          (cmdP <**> helper)
          (fullDesc <> progDesc "LLM code review for GHC merge requests; writes review.md and prints its path.")
      )
  home <- getHomeDirectory
  let dataDir = home </> "glahico"
  case cmd of
    PublishCmd publishOpts -> runPublish dataDir publishOpts
    ReviewCmd opts -> runReview dataDir opts

runReview :: FilePath -> Opts -> IO ()
runReview dataDir opts = do
  adhocText <- traverse (\case AdhocText t -> pure t; AdhocFile p -> TIO.readFile p) opts.adhoc
  tgt <- either die pure (parseTarget opts.target)
  resolved <- case tgt of
    MrTarget project iid -> do
      putStrLn ("Target: !" <> show iid <> " in " <> T.unpack project)
      resolveMr dataDir project iid
    PrTarget repo@(GitHubRepo name) number@(PrNumber n) -> do
      putStrLn ("Target: #" <> show n <> " in " <> T.unpack name)
      resolvePr dataDir repo number
    RangeTarget a b -> do
      putStrLn ("Target: local range " <> T.unpack a <> ".." <> T.unpack b)
      resolveLocal dataDir a b
    CommitTarget c -> do
      putStrLn ("Target: local commit " <> T.unpack c)
      resolveLocal dataDir (c <> "^") c
  now <- getCurrentTime
  let ts = formatTime defaultTimeLocale "%Y%m%dT%H%M%S" now
      runDir = dataDir </> "runs" </> resolved.slug </> ts
  createDirectoryIfMissing True (runDir </> "verdicts")
  -- Read by `publish`, which posts a pull request's review differently.
  BL.writeFile (runDir </> "target.json") $
    AP.encodePretty $ case tgt of
      MrTarget project iid -> object ["forge" .= ("gitlab" :: Text), "project" .= project, "number" .= iid]
      PrTarget (GitHubRepo repo) (PrNumber n) -> object ["forge" .= ("github" :: Text), "project" .= repo, "number" .= n]
      _ -> object ["forge" .= ("local" :: Text)]
  putStrLn ("Run directory: " <> runDir)
  putStrLn "Assembling context pack ..."
  (ctxDir, truncs) <- buildContext resolved runDir
  putStrLn ("Context pack: " <> ctxDir)
  let isMr = isJust resolved.mr
      wording = wordingFor tgt
  finderPrompt <- renderFinderPrompt wording ctxDir isMr adhocText
  TIO.writeFile (runDir </> "finder.prompt.txt") finderPrompt
  putStrLn ("Running finder (" <> opts.finderModel <> ", effort " <> opts.finderEffort <> ") ...")
  finderRun <-
    runClaude
      resolved.worktree
      ctxDir
      (runDir </> "finder.envelope.json")
      opts.finderModel
      opts.finderEffort
      finderSchema
      finderPrompt
  Findings allFindings <-
    decodeStructured "finder" (runDir </> "finder.envelope.json") finderRun.structured
  BL.writeFile (runDir </> "findings.json") (AP.encodePretty (Findings allFindings))
  putStrLn ("Finder reported " <> show (length allFindings) <> " finding(s).")
  when (length allFindings > 20) $
    warn
      ( "finder reported " <> show (length allFindings)
          <> " findings; verifying only the first 20."
      )
  let toVerify = take 20 allFindings
      unverifiedN = length allFindings - length toVerify
  verified <- forM (zip [(1 :: Int) ..] toVerify) $ \(n, f) -> do
    putStrLn ("Verifying " <> show n <> "/" <> show (length toVerify) <> ": " <> T.unpack f.title <> " ...")
    vPrompt <- renderVerifierPrompt wording ctxDir isMr f
    let vBase = runDir </> "verdicts" </> ("f" <> show n)
    TIO.writeFile (vBase <> ".prompt.txt") vPrompt
    run <-
      runClaude
        resolved.worktree
        ctxDir
        (vBase <> ".envelope.json")
        opts.verifierModel
        opts.verifierEffort
        verifierSchema
        vPrompt
    verdict <- decodeStructured ("verifier f" <> show n) (vBase <> ".envelope.json") run.structured
    BL.writeFile (vBase <> ".json") (AP.encodePretty (embedFinding f verdict))
    -- At most one snippet in the review; the full list stays in the verdict.
    snips <- mapM (extractSnippet resolved.worktree) (take 1 verdict.snippets)
    pure (f, verdict, snips, run)
  commit <- glahicoCommit
  dirtyPrompts <- uncommittedPromptFiles
  (targetDesc, titleSuffix) <- case resolved.mr of
    Just md ->
      pure
        ( "[" <> md.project <> md.ref <> "](" <> md.url <> ")"
        , md.title <> " (" <> md.ref <> ")"
        )
    Nothing
      | RangeTarget a b <- tgt ->
          pure (dup ("local range " <> a <> ".." <> b))
      | otherwise -> do
          subject <- gitIn resolved.worktree ["log", "-1", "--format=%s", T.unpack resolved.headSha]
          pure (dup (subject <> " (" <> T.take 7 resolved.headSha <> ")"))
  let report =
        Report
          { targetDesc
          , titleSuffix
          , baseSha = resolved.baseSha
          , headSha = resolved.headSha
          , commit
          , finderStage =
              Stage
                opts.finderModel
                opts.finderEffort
                (disclosedUsage opts.finderModel finderRun.usage)
                (maybeToList finderRun.finalContext)
          , verifierStage =
              Stage
                opts.verifierModel
                opts.verifierEffort
                (disclosedUsage opts.verifierModel (sumUsage [run.usage | (_, _, _, run) <- verified]))
                (mapMaybe (\(_, _, _, run) -> run.finalContext) verified)
          , truncations = truncs
          , totalFindings = length allFindings
          , unverified = unverifiedN
          , verified = [(f, v, s) | (f, v, s, _) <- verified]
          , adhocPrompt = adhocText
          , uncommittedPrompts = dirtyPrompts
          }
      reviewPath = runDir </> "review.md"
  TIO.writeFile reviewPath (renderReview report)
  putStrLn (costLine finderRun.cost [run.cost | (_, _, _, run) <- verified])
  putStrLn reviewPath
  -- Only on success: an exception earlier keeps the worktree for debugging.
  removeWorktree resolved.worktree
