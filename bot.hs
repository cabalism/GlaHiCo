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

-- The GlaHiCo review bot, @glahico-bot-unofficial on gitlab.haskell.org.
-- Turns review requests (to-dos of the bot account) into glahico.hs runs
-- and posts the results. See BOT.md for the workflow and the rationale.

module Main (main) where

import Control.Monad (forM, unless, when)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, eitherDecodeFileStrict)
import Data.Aeson.Encode.Pretty qualified as AP
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit, isPunctuation, isSpace)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import GHC.Generics (Generic)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), die)
import System.FilePath (takeExtension, (</>))
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Process.Typed (nullStream, proc, readProcess, setEnv, setStdin)

--------------------------------------------------------------------------------
-- CLI
--------------------------------------------------------------------------------

data Cmd = PollCmd PollOpts

data PollOpts = PollOpts
  { todoState :: String
  , dryRun :: Bool
  }

cmdP :: Parser Cmd
cmdP =
  hsubparser
    ( command
        "poll"
        ( info
            (PollCmd <$> pollP)
            (progDesc "List the bot's review requests and record new ones")
        )
    )

pollP :: Parser PollOpts
pollP =
  PollOpts
    <$> option
      (eitherReader stateReader)
      ( long "state"
          <> metavar "pending|done|all"
          <> value "pending"
          <> showDefault
          <> help "Which to-dos to list; only pending ones are recorded"
      )
    <*> switch (long "dry-run" <> help "Triage and print, but write no request files")
  where
    stateReader s
      | s `elem` ["pending", "done", "all"] = Right s
      | otherwise = Left ("expected pending, done or all, got " <> show s)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  dataDir <- (</> "glahico") <$> getHomeDirectory
  cmd <-
    execParser $
      info
        (cmdP <**> helper)
        (fullDesc <> progDesc "GlaHiCo review bot; see BOT.md")
  case cmd of
    PollCmd opts -> runPoll dataDir opts

--------------------------------------------------------------------------------
-- Bot identity and tokens
--------------------------------------------------------------------------------

botUser :: Text
botUser = "glahico-bot-unofficial"

-- | The read-only token (scope @read_api@) serves everything that only
-- reads: it is readable by the user and by agents. The write token stays
-- behind sudo and is read only by the posting path.
readToken :: FilePath -> IO String
readToken dataDir = do
  let path = dataDir </> "bot-token-read"
  exists <- doesFileExist path
  unless exists $
    die
      ( path <> " not found.\n"
          <> "Create a personal access token for " <> T.unpack botUser
          <> " with scope `read_api`,\nsave it there (single line) and chmod 600 it."
      )
  T.unpack . T.strip <$> TIO.readFile path

-- | GET from the GitLab API as the bot. The token travels in the child's
-- environment, never on argv, so neither ps nor error messages show it.
glabGet :: String -> String -> IO Value
glabGet token endpoint = do
  env <- getEnvironment
  let args = ["api", "--hostname", "gitlab.haskell.org", endpoint]
  (ec, out, err) <-
    readProcess (setEnv (("GITLAB_TOKEN", token) : env) (setStdin nullStream (proc "glab" args)))
  case ec of
    ExitFailure n ->
      die ("glab " <> unwords args <> " failed (exit " <> show n <> "):\n" <> T.unpack (lbsText err))
    ExitSuccess -> either (\e -> die ("glab api " <> endpoint <> ": bad JSON: " <> e)) pure (eitherDecode out)

lbsText :: BL.ByteString -> Text
lbsText = TE.decodeUtf8Lenient . BL.toStrict

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

vPath :: [Key.Key] -> Value -> Maybe Value
vPath [] v = Just v
vPath (k : ks) v = vKey k v >>= vPath ks

vPathText :: [Key.Key] -> Value -> Maybe Text
vPathText ks v = vPath ks v >>= \case String t -> Just t; _ -> Nothing

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

-- | One review request, keyed by the GitLab to-do that announced it.
-- Stored as @~/glahico/bot/requests/<todoId>.json@. The to-do stays pending
-- in GitLab until the posting path marks it done, so a lost file costs
-- nothing but a re-poll.
data Request = Request
  { todoId :: Int
  , action :: Text
  -- ^ GitLab's @action_name@: review_requested, directly_addressed, mentioned
  , project :: Text
  , projectId :: Int
  , iid :: Int
  , title :: Text
  , webUrl :: Text
  , requester :: Text
  , author :: Text
  , headSha :: Text
  -- ^ MR head when polled; the run resolves the MR afresh
  , changes :: Text
  -- ^ GitLab's @changes_count@: a number, or "100+"
  , requestedAt :: Text
  , polledAt :: Text
  , status :: Text
  -- ^ pending | running | generated | posted | skipped
  , reason :: Maybe Text
  -- ^ why skipped
  , runDir :: Maybe FilePath
  , finderModel :: Maybe Text
  , finderEffort :: Maybe Text
  , verifierModel :: Maybe Text
  , verifierEffort :: Maybe Text
  , snippetUrl :: Maybe Text
  }
  deriving (Generic, Show)

instance FromJSON Request

instance ToJSON Request

requestsDir :: FilePath -> FilePath
requestsDir dataDir = dataDir </> "bot" </> "requests"

requestPath :: FilePath -> Int -> FilePath
requestPath dataDir tid = requestsDir dataDir </> (show tid <> ".json")

loadRequests :: FilePath -> IO [Request]
loadRequests dataDir = do
  let dir = requestsDir dataDir
  createDirectoryIfMissing True dir
  names <- filter ((== ".json") . takeExtension) <$> listDirectory dir
  forM (sortOn numericName names) $ \name -> do
    let path = dir </> name
    eitherDecodeFileStrict path >>= either (\e -> die (path <> ": " <> e)) pure
  where
    numericName = read @Int . takeWhile isDigit

saveRequest :: FilePath -> Request -> IO ()
saveRequest dataDir r = do
  let path = requestPath dataDir r.todoId
  BL.writeFile path (AP.encodePretty' (AP.defConfig {AP.confCompare = compare}) r <> "\n")

-- | The request body must be the mention followed by exactly @review@,
-- case-insensitively, give or take punctuation ("review!" is fine, "review
-- please" is not). Unrecognised mentions are listed but not acted on, see
-- BOT.md "Requesting a review".
isReviewCommand :: Text -> Bool
isReviewCommand body =
  case T.stripPrefix ("@" <> T.toLower botUser) (T.toLower (T.strip body)) of
    Just rest -> T.dropAround (\c -> isSpace c || isPunctuation c) rest == "review"
    Nothing -> False

-- | Decide what to do with a pending to-do, given the requests already
-- recorded for the same MR.
triage :: [Request] -> Request -> Text -> (Text, Maybe Text)
triage prior r body
  | r.action `notElem` ["review_requested", "directly_addressed", "mentioned"] =
      skip ("to-do action " <> r.action)
  | r.action /= "review_requested" && not (isReviewCommand body) = skip "unrecognised command"
  | any (\p -> p.status == "posted" && p.headSha == r.headSha) sameMr = skip "head already reviewed"
  | otherwise = ("pending", Nothing)
  where
    sameMr = filter (\p -> p.project == r.project && p.iid == r.iid) prior
    skip why = ("skipped", Just why)

-- | Build the request record from a to-do's JSON. The to-do embeds the
-- current MR as @target@, so no second fetch is needed.
requestFromTodo :: Text -> Value -> Either String (Request, Text)
requestFromTodo now todo = do
  let mr = fromMaybe Null (vKey "target" todo)
      need what = maybe (Left ("to-do: missing " <> what)) Right
  todoId <- need "id" (vInt "id" todo)
  actionName <- need "action_name" (vText "action_name" todo)
  requester <- need "author.username" (vPathText ["author", "username"] todo)
  requestedAt <- need "created_at" (vText "created_at" todo)
  project <- need "target.references.full" (vPathText ["references", "full"] mr)
  projectId <- need "target.project_id" (vInt "project_id" mr)
  iid <- need "target.iid" (vInt "iid" mr)
  title <- need "target.title" (vText "title" mr)
  webUrl <- need "target.web_url" (vText "web_url" mr)
  author <- need "target.author.username" (vPathText ["author", "username"] mr)
  headSha <- need "target.sha" (vText "sha" mr)
  let changes = fromMaybe "?" (vText "changes_count" mr)
      body = fromMaybe "" (vText "body" todo)
      mrState = fromMaybe "?" (vText "state" mr)
      req =
        Request
          { todoId
          , action = actionName
          , project = T.takeWhile (/= '!') project
          , projectId
          , iid
          , title
          , webUrl
          , requester
          , author
          , headSha
          , changes
          , requestedAt
          , polledAt = now
          , status = if mrState == "opened" then "pending" else "skipped"
          , reason = if mrState == "opened" then Nothing else Just ("MR is " <> mrState)
          , runDir = Nothing
          , finderModel = Nothing
          , finderEffort = Nothing
          , verifierModel = Nothing
          , verifierEffort = Nothing
          , snippetUrl = Nothing
          }
  pure (req, body)

--------------------------------------------------------------------------------
-- poll
--------------------------------------------------------------------------------

runPoll :: FilePath -> PollOpts -> IO ()
runPoll dataDir opts = do
  token <- readToken dataDir
  me <- glabGet token "user"
  let who = fromMaybe "?" (vText "username" me)
  when (who /= botUser) $
    die ("token belongs to @" <> T.unpack who <> ", expected @" <> T.unpack botUser)
  now <- T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime
  prior <- loadRequests dataDir
  let states = case opts.todoState of
        "all" -> ["pending", "done"]
        s -> [s]
  todos <- concat <$> forM states (\s -> toList' <$> glabGet token ("todos?type=MergeRequest&state=" <> s <> "&per_page=100"))
  rows <- forM todos $ \todo -> do
    (fresh, body) <- either die pure (requestFromTodo now todo)
    let todoState = fromMaybe "?" (vText "state" todo)
        known = [p | p <- prior, p.todoId == fresh.todoId]
    case known of
      p : _ -> pure (todoState, p, True)
      [] -> do
        let (st, why) = triage prior fresh body
            r = if fresh.status == "skipped" then fresh else fresh {status = st, reason = why}
        -- Only live requests become files; done to-dos are history.
        when (todoState == "pending" && not opts.dryRun) $ saveRequest dataDir r
        pure (todoState, r, False)
  TIO.putStr (renderTable prior rows)
  let waiting st = length [p | p <- prior, p.status == st]
  putStrLn ""
  putStrLn
    ( show (length rows) <> " to-do(s) listed, "
        <> show (length [() | (_, _, False) <- rows]) <> " new"
        <> (if opts.dryRun then " (dry run, nothing written)" else "")
        <> ". Recorded requests: " <> show (waiting "pending") <> " pending, "
        <> show (waiting "running") <> " running, " <> show (waiting "generated") <> " generated."
    )
  where
    toList' (Array xs) = toList xs
    toList' _ = []

renderTable :: [Request] -> [(Text, Request, Bool)] -> Text
renderTable prior rows = T.unlines (map fmt (hdr : map row rows))
  where
    hdr = ["todo", "mr", "head", "chg", "trigger", "by", "prev", "status", "title"]
    row (todoState, r, known) =
      [ T.pack (show r.todoId) <> (if todoState == "done" then "*" else "")
      , r.project <> "!" <> T.pack (show r.iid)
      , T.take 8 r.headSha
      , r.changes
      , shortAction r.action
      , r.requester
      , T.pack (show (postedBefore r))
      , r.status <> maybe "" (\why -> " (" <> why <> ")") r.reason <> (if known then "" else " new")
      , T.take 50 r.title
      ]
    postedBefore r = length [p | p <- prior, p.project == r.project, p.iid == r.iid, p.status == "posted"]
    shortAction = \case
      "review_requested" -> "request"
      "directly_addressed" -> "mention"
      "mentioned" -> "mention"
      a -> a
    widths = foldr (zipWith max . map T.length) (repeat 0) (hdr : map row rows)
    fmt cells = T.stripEnd (T.intercalate "  " (zipWith pad widths cells))
    pad w c = c <> T.replicate (w - T.length c) " "
