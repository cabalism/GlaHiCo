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
import Data.Char (isAlphaNum, isDigit, toLower)
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
import System.Process.Typed (nullStream, proc, readProcess, runProcess, setEnv, setStdin, setWorkingDir)

--------------------------------------------------------------------------------
-- Options & CLI
--------------------------------------------------------------------------------

data Adhoc = AdhocText Text | AdhocFile FilePath

data Opts = Opts
  { target :: String
  , finderModel :: String
  , verifierModel :: String
  , finderEffort :: String
  , verifierEffort :: String
  , adhoc :: Maybe Adhoc
  }

optsP :: Parser Opts
optsP =
  Opts
    <$> strArgument
      (metavar "TARGET" <> help "MR number (14892 or !14892), gitlab.haskell.org MR URL, or local commit range (BASE..HEAD)")
    <*> strOption
      (long "finder-model" <> metavar "ALIAS" <> value "opus" <> showDefault <> help "Model for the finder stage")
    <*> strOption
      (long "verifier-model" <> metavar "ALIAS" <> value "opus" <> showDefault <> help "Model for the verifier stage")
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

data Target = MrTarget Text Int | LocalRange Text

parseTarget :: String -> Either String Target
parseTarget s
  | not (null s), all isDigit s = Right (MrTarget "ghc/ghc" (read s))
  | '!' : ds <- s, not (null ds), all isDigit ds = Right (MrTarget "ghc/ghc" (read ds))
  | Just rest <- stripPrefix "https://gitlab.haskell.org/" s = parseMrUrl rest
  | "http://" `isPrefixOf` s || "https://" `isPrefixOf` s =
      Left "only gitlab.haskell.org merge-request URLs are supported"
  | ".." `T.isInfixOf` T.pack s = Right (LocalRange (T.pack s))
  | otherwise = Left ("cannot parse target: " <> s)

parseMrUrl :: String -> Either String Target
parseMrUrl rest
  | (proj, tl) <- T.breakOn "/-/merge_requests/" (T.pack rest)
  , Just tl' <- T.stripPrefix "/-/merge_requests/" tl
  , ds <- T.takeWhile isDigit tl'
  , not (T.null ds)
  , not (T.null proj) =
      Right (MrTarget proj (read (T.unpack ds)))
  | otherwise = Left ("cannot parse GitLab MR URL: https://gitlab.haskell.org/" <> rest)

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

tshow :: Show a => a -> Text
tshow = T.pack . show

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

-- | Fetch up to @maxPages@ pages; the 'Bool' reports whether the page cap cut
-- the result short (a truncation the byte caps cannot see).
glabPaged :: String -> Int -> IO ([Value], Bool)
glabPaged endpoint maxPages = go 1
  where
    sep = if '?' `elem` endpoint then "&" else "?"
    go :: Int -> IO ([Value], Bool)
    go n
      | n > maxPages = pure ([], True)
      | otherwise = do
          v <- glabJson (endpoint <> sep <> "per_page=100&page=" <> show n)
          case v of
            Array xs ->
              let items = toList xs
               in if length items < 100
                    then pure (items, False)
                    else (\(more, capped) -> (items ++ more, capped)) <$> go (n + 1)
            _ -> die ("glab api " <> endpoint <> ": expected a JSON array")

--------------------------------------------------------------------------------
-- Mirror & worktree
--------------------------------------------------------------------------------

data MrData = MrData {project :: Text, iid :: Int, meta :: Value}

data Resolved = Resolved
  { slug :: String
  , worktree :: FilePath
  , baseSha :: Text
  , headSha :: Text
  , mr :: Maybe MrData
  }

urlEncodeProject :: Text -> String
urlEncodeProject = T.unpack . T.replace "/" "%2F"

projectSlug :: Text -> String
projectSlug = T.unpack . T.replace "/" "-"

ensureMirror :: FilePath -> IO ()
ensureMirror mirror = do
  exists <- doesDirectoryExist mirror
  unless exists $ do
    putStrLn ("One-time setup: mirroring ghc/ghc (multiple GB) into " <> mirror <> " ...")
    createDirectoryIfMissing True (takeDirectory mirror)
    inherit "git" ["clone", "--mirror", "git@gitlab.haskell.org:ghc/ghc.git", mirror]

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
        warn ("worktree " <> wt <> " is dirty; agents are read-only, so this is unexpected. Not cleaning up.")
      void (gitIn wt ["checkout", "--detach", T.unpack headSha])
    else do
      createDirectoryIfMissing True (takeDirectory wt)
      void (gitIn srcRepo ["worktree", "prune"])
      gitLoud srcRepo ["worktree", "add", "--detach", wt, T.unpack headSha]
  initSubmodules subStores wt

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
    let update =
          tryCapture "git" $
            ["-C", wt, "-c", "protocol.file.allow=always"]
              <> cfgs
              <> ["submodule", "update", "--init", "--jobs", "4"]
    r <- update >>= \case
      Right ok -> pure (Right ok)
      Left _ -> do
        putStrLn "Refreshing submodule stores ..."
        forM_ names $ \n ->
          void (tryCapture "git" ["-C", stores </> n, "fetch", "--prune", "--quiet"])
        update
    case r of
      Right _ -> void (gitIn wt ["submodule", "sync", "--quiet"])
      Left _ -> do
        warn "local submodule stores were insufficient; falling back to canonical remotes"
        void (gitIn wt ["submodule", "sync", "--quiet"])
        gitLoud wt ["submodule", "update", "--init", "--jobs", "4"]

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
  ensureMirror mirror
  remote <- if project == "ghc/ghc" then pure "origin" else ensureRemote mirror project
  putStrLn ("Fetching !" <> show iid <> " from " <> T.unpack project <> " ...")
  gitLoud
    mirror
    [ "fetch"
    , remote
    , "+refs/merge-requests/" <> show iid <> "/head:refs/glahico/" <> slug
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
  pure Resolved {slug, worktree = wt, baseSha, headSha, mr = Just (MrData project iid meta)}

resolveLocal :: FilePath -> Text -> IO Resolved
resolveLocal dataDir spec = do
  (a0, b0) <- case T.breakOn ".." spec of
    (a, rest)
      | Just b <- T.stripPrefix ".." rest -> pure (a, T.dropWhile (== '.') b)
    _ -> die ("cannot parse commit range: " <> T.unpack spec)
  let aSpec = if T.null a0 then "HEAD" else a0
      bSpec = if T.null b0 then "HEAD" else b0
  repoTop <- T.strip . lbsText <$> capture "git" ["rev-parse", "--show-toplevel"]
  let repo = T.unpack repoTop
  headSha <- gitIn repo ["rev-parse", "--verify", T.unpack bSpec <> "^{commit}"]
  baseSha <- gitIn repo ["merge-base", T.unpack aSpec, T.unpack bSpec]
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

issueRefs :: Text -> [Int]
issueRefs = go . T.unpack
  where
    go [] = []
    go ('#' : rest) =
      let (ds, rest') = span isDigit rest
          len = length ds
       in if len >= 3 && len <= 6 then read ds : go rest' else go rest'
    go (_ : rest) = go rest

authorOf :: Value -> Text
authorOf v = case vKey "author" v of
  Just a -> fromMaybe "?" (vText "name" a) <> maybe "" (\u -> " (@" <> u <> ")") (vText "username" a)
  Nothing -> "?"

noteMarkdown :: Value -> Text
noteMarkdown n =
  "## " <> authorOf n <> " — " <> fromMaybe "" (vText "created_at" n)
    <> "\n\n" <> fromMaybe "" (vText "body" n) <> "\n"

mrMarkdown :: MrData -> Text
mrMarkdown md =
  T.unlines
    [ "# " <> fromMaybe "(no title)" (vText "title" m) <> " (!" <> tshow md.iid <> ")"
    , ""
    , "- Project: " <> md.project
    , "- Author: " <> authorOf m
    , "- Branches: " <> branch "source_branch" <> " → " <> branch "target_branch"
    , "- Labels: " <> (if T.null labels then "(none)" else labels)
    , "- URL: " <> fromMaybe "" (vText "web_url" m)
    , ""
    , "## Description"
    , ""
    , fromMaybe "" (vText "description" m)
    ]
  where
    m = md.meta
    branch k = fromMaybe "?" (vText k m)
    labels = T.intercalate ", " [l | String l <- vArray "labels" m]

discussionMarkdown :: [Value] -> Text
discussionMarkdown discussions
  | null notes = "# MR discussion\n\n(no non-system comments)\n"
  | otherwise = "# MR discussion\n\n" <> T.intercalate "\n" (map noteMarkdown notes)
  where
    notes = [n | d <- discussions, n <- vArray "notes" d, not (vBoolIs "system" True n)]

issueMarkdown :: Int -> Value -> [Value] -> Text
issueMarkdown n issue notes0 =
  T.unlines
    [ "# Issue #" <> tshow n <> ": " <> fromMaybe "(no title)" (vText "title" issue)
    , ""
    , "- State: " <> fromMaybe "?" (vText "state" issue)
    , "- Author: " <> authorOf issue
    , "- URL: " <> fromMaybe "" (vText "web_url" issue)
    , ""
    , "## Description"
    , ""
    , fromMaybe "" (vText "description" issue)
    , ""
    ]
    <> T.intercalate "\n" (map noteMarkdown notes)
  where
    notes = take 100 [x | x <- notes0, not (vBoolIs "system" True x)]

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
  forM_ res.mr $ \md -> do
    let enc = urlEncodeProject md.project
    putCapped (ctx </> "mr.md") "mr.md" (50 * 1024) (mrMarkdown md)
    putStrLn "Fetching MR discussion ..."
    (discussions, discCapped) <-
      glabPaged ("projects/" <> enc <> "/merge_requests/" <> show md.iid <> "/discussions") 5
    when discCapped $
      modifyIORef' truncsRef (++ ["discussion.md: more than 5 pages of discussions, remainder omitted"])
    putCapped (ctx </> "discussion.md") "discussion.md" (200 * 1024) (discussionMarkdown discussions)
    let refs = nub (issueRefs commits ++ issueRefs (fromMaybe "" (vText "description" md.meta)))
    when (length refs > 5) $
      modifyIORef'
        truncsRef
        (++ ["linked issues: " <> tshow (length refs) <> " referenced, only the first 5 included"])
    let picked = take 5 refs
    unless (null picked) (createDirectoryIfMissing True (ctx </> "issues"))
    forM_ picked $ \n -> do
      putStrLn ("Fetching issue #" <> show n <> " ...")
      tryGlabJson ("projects/ghc%2Fghc/issues/" <> show n) >>= \case
        Left err -> warn ("could not fetch issue #" <> show n <> ": " <> T.unpack err)
        Right issue -> do
          eNotes <- tryGlabJson ("projects/ghc%2Fghc/issues/" <> show n <> "/notes?per_page=100")
          let notes = case eNotes of
                Right (Array xs) -> toList xs
                _ -> []
          when (length notes == 100) $
            modifyIORef'
              truncsRef
              (++ [T.pack ("issues/" <> show n <> ".md") <> ": only the first page (100) of comments fetched"])
          putCapped
            (ctx </> "issues" </> show n <> ".md")
            (T.pack ("issues/" <> show n <> ".md"))
            (50 * 1024)
            (issueMarkdown n issue notes)
  truncs <- readIORef truncsRef
  pure (ctx, truncs)

--------------------------------------------------------------------------------
-- Prompt loading & JSON schemas
--------------------------------------------------------------------------------

-- Cabal resolves the script to an absolute path before compiling, so __FILE__
-- locates the checkout this binary was built from (prompts/, git metadata).
scriptDir :: FilePath
scriptDir = takeDirectory __FILE__

loadPrompt :: FilePath -> Bool -> IO Text
loadPrompt name isMr = do
  let path = scriptDir </> "prompts" </> name
  ok <- doesFileExist path
  unless ok (die ("prompt file not found: " <> path))
  raw <- TIO.readFile path
  pure $
    if isMr
      then raw
      else T.unlines (filter (not . ("[MR targets only]" `T.isInfixOf`)) (T.lines raw))

renderFinderPrompt :: FilePath -> Bool -> Maybe Text -> IO Text
renderFinderPrompt ctxDir isMr adhocText = do
  raw <- loadPrompt "finder.md" isMr
  let p = T.replace "{ctx}" (T.pack ctxDir) raw
  pure $ case adhocText of
    Nothing -> p
    Just extra -> p <> "\n## Additional instructions for this run\n\n" <> extra <> "\n"

renderVerifierPrompt :: FilePath -> Bool -> Finding -> IO Text
renderVerifierPrompt ctxDir isMr f = do
  raw <- loadPrompt "verifier.md" isMr
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
    , "required" .= map jstr ["verdict", "relevant", "disprove_evidence", "prove_evidence", "relevance_rationale", "writeup", "snippets"]
    , "properties"
        .= object
          [ "verdict" .= object ["type" .= jstr "string", "enum" .= map jstr ["confirmed", "uncertain", "refuted"]]
          , "relevant" .= object ["type" .= jstr "boolean"]
          , "disprove_evidence" .= object ["type" .= jstr "string"]
          , "prove_evidence" .= object ["type" .= jstr "string"]
          , "relevance_rationale" .= object ["type" .= jstr "string"]
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
  , writeup :: Text
  , snippets :: [Snippet]
  }
  deriving (Generic, Show)

instance FromJSON Verdict

instance ToJSON Verdict

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
  }

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
      env' =
        ("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1")
          : filter ((/= "CLAUDE_CODE_DISABLE_AUTO_MEMORY") . fst) hostEnv
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
      -- size; fall back to the call totals when iterations are absent.
      finalContext = do
        u <- vKey "usage" v
        let src = case vArray "iterations" u of
              [] -> u
              its -> last its
        case mapMaybe (`vInt` src) ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] of
          [] -> Nothing
          xs -> Just (sum xs)
  pure ClaudeRun {structured, usage, finalContext}

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
      -- .T files are the Python testsuite driver files.
      (lang, commentPrefix) = case takeExtension (T.unpack s.file) of
        e
          | e `elem` [".hs", ".lhs", ".hs-boot"] -> ("haskell", Just "-- ")
          | e `elem` [".c", ".h", ".cmm"] -> ("c", Just "// ")
          | e `elem` [".py", ".T"] -> ("python", Just "# ")
          | otherwise -> ("", Nothing)
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
            -- Arrow-comment marker on the key line, when we know the
            -- language's comment syntax.
            marked = case commentPrefix of
              Nothing -> picked
              Just p ->
                [ if n == s.key_line then l <> "  " <> T.strip p <> " <==" else l
                | (n, l) <- zip [lo ..] picked
                ]
        pure $
          if null picked
            then Nothing
            else Just (T.unlines (marked ++ ["[snippet truncated]" | truncated]))
  pure RenderedSnippet {label, lang, commentedLabel, body}

data Report = Report
  { targetDesc :: Text
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

renderReview :: Report -> Text
renderReview r =
  T.unlines
    ( headerLines ++ findingsSection ++ lowSection ++ adhocSection
        ++ dirtySection ++ disclosureSection ++ disclaimerLines
    )
  where
    confirmedRel = [fv | fv@(_, v, _) <- r.verified, v.verdict == "confirmed", v.relevant]
    uncertainRel = [fv | fv@(_, v, _) <- r.verified, v.verdict == "uncertain", v.relevant]
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
        ++ [ tshow (length droppedFvs) <> " dropped ("
               <> T.intercalate ", " [f.id <> ": " <> dropReason v | (f, v) <- droppedFvs]
               <> ")"
           | not (null droppedFvs)
           ]
    unverifiedParts =
      [ tshow r.unverified <> " not verified (preserved in findings.json in the run directory)"
      | r.unverified > 0
      ]
    droppedFvs =
      [ (f, v)
      | (f, v, _) <- r.verified
      , not (v.relevant && (v.verdict == "confirmed" || v.verdict == "uncertain"))
      ]
    dropReason (v :: Verdict)
      | v.verdict == "refuted" = "refuted"
      | otherwise = v.verdict <> " and judged not relevant"
    block (f, v, snips) =
      [ "### " <> f.id <> ": " <> f.title
      , ""
      ]
        ++ concatMap snippetLines snips
        ++ [ v.writeup
           , ""
           ]
    -- Four-backtick fences, like the ad-hoc appendix, so embedded ``` can't
    -- break out. The location goes inside the fence as a comment when we know
    -- the language's comment syntax; a label line above is the fallback.
    snippetLines (s :: RenderedSnippet) = case s.body of
      Nothing -> [backticked s.label, "", "_snippet unavailable_", ""]
      Just b ->
        case s.commentedLabel of
          Just c -> ["````" <> s.lang, c, T.stripEnd b, "````", ""]
          Nothing -> [backticked s.label, "", "````" <> s.lang, T.stripEnd b, "````", ""]
    headerLines = ["# GlaHiCo review", ""] ++ summaryLines
    summaryLines
      | null confirmedRel && null uncertainRel =
          [ if r.totalFindings == 0
              then "_The finder reported no findings._"
              else "_No findings survived verification._"
          , ""
          ]
      | otherwise =
          linkGroup "High-confidence findings:" confirmedRel
            ++ linkGroup "Low-confidence findings:" uncertainRel
    linkGroup label fvs
      | null fvs = []
      | otherwise =
          label
            : ""
            : [ "- [" <> heading <> "](#" <> headingAnchor heading <> ")"
              | (f, _, _) <- fvs
              , let heading = f.id <> ": " <> f.title
              ]
            ++ [""]
    findingsSection
      | null confirmedRel = []
      | otherwise = "## High-confidence findings" : "" : concatMap block confirmedRel
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
            ++ concatMap block uncertainRel
    adhocSection = case r.adhocPrompt of
      Nothing -> []
      Just t ->
        [ "## Appendix: ad-hoc prompt additions"
        , ""
        , "The following instructions were appended to the finder prompt for this run:"
        , ""
        , "````"
        , T.stripEnd t
        , "````"
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
            (\(name, content) -> ["### " <> T.pack name, "", "````", T.stripEnd content, "````", ""])
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
  opts <-
    execParser
      ( info
          (optsP <**> helper)
          (fullDesc <> progDesc "LLM code review for GHC merge requests; writes review.md and prints its path.")
      )
  adhocText <- traverse (\case AdhocText t -> pure t; AdhocFile p -> TIO.readFile p) opts.adhoc
  tgt <- either die pure (parseTarget opts.target)
  home <- getHomeDirectory
  let dataDir = home </> "glahico"
  resolved <- case tgt of
    MrTarget project iid -> do
      putStrLn ("Target: !" <> show iid <> " in " <> T.unpack project)
      resolveMr dataDir project iid
    LocalRange spec -> do
      putStrLn ("Target: local range " <> T.unpack spec)
      resolveLocal dataDir spec
  now <- getCurrentTime
  let ts = formatTime defaultTimeLocale "%Y%m%dT%H%M%S" now
      runDir = dataDir </> "runs" </> resolved.slug </> ts
  createDirectoryIfMissing True (runDir </> "verdicts")
  putStrLn ("Run directory: " <> runDir)
  putStrLn "Assembling context pack ..."
  (ctxDir, truncs) <- buildContext resolved runDir
  putStrLn ("Context pack: " <> ctxDir)
  let isMr = isJust resolved.mr
  finderPrompt <- renderFinderPrompt ctxDir isMr adhocText
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
    vPrompt <- renderVerifierPrompt ctxDir isMr f
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
  let targetDesc = case resolved.mr of
        Just md ->
          "[" <> md.project <> "!" <> tshow md.iid
            <> "](https://gitlab.haskell.org/" <> md.project <> "/-/merge_requests/" <> tshow md.iid <> ")"
        Nothing -> "local range " <> T.pack opts.target
      report =
        Report
          { targetDesc
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
  putStrLn reviewPath
