{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs    #-}

import qualified Schema as DB
import Network.Wai.Middleware.RequestLogger(logStdout)
import qualified Web.Scotty as WS
import App.SlackIntegration(notifyNewRelease)
import Control.Monad.Trans(MonadIO, liftIO)
import qualified Data.Aeson as DA
import qualified Control.Monad.State.Lazy as MS
import Data.Time.Clock(getCurrentTime)
import StringHelpers(lazyByteStringToString)
import Network.Wai.Middleware.Static
import Data.Monoid(mconcat)
import qualified Data.Text.Lazy as T
import qualified Data.Text as DT
import PivotalTracker.Story
import Control.Applicative((<$>))
import qualified Data.Text.Lazy as LT
import Control.Monad(forM)
import PivotalTracker.Label(updateLabelsOnStories)
import Database.Persist
import Control.Monad.Trans.Reader( ReaderT(..))
import Queries.Release(getReleases, getRelease)
import System.Environment(getEnv)
import Control.Monad(liftM, liftM5)
import Database.Persist.Postgresql
import qualified Data.ByteString.Char8 as BCH
import Control.Monad.Logger(runStdoutLoggingT)
import qualified Data.ByteString.Lazy as BL
import App.Environment
import World


{- connStr = "host=localhost dbname=flow_api user=gust port=5432" -}

runDbIO :: BCH.ByteString -> SqlPersistM a -> IO a
runDbIO connStr statement = runStdoutLoggingT $ withPostgresqlConn connStr $ \connection ->
          liftIO $ runSqlPersistM statement connection

labelStories :: World m => String -> Environment -> BL.ByteString -> m ()
labelStories label environment gitLog =
  flip runReaderT environment $ do
    stories <- fmap story `liftM` getStories gitLog
    updateLabelsOnStories label stories

getReleaseStory :: DB.ReleaseId -> DB.PivotalStoryId -> DB.ReleaseStory
getReleaseStory = DB.ReleaseStory

insertPivotalStory (PivotalStory story pivotalUsers) = do
  pivotalUsers <- mapM insertIfNew pivotalUsers
  let ownerIds = fmap entityKey pivotalUsers
  storyId <- entityKey <$> insertIfNew story
  pivotalStoryOwnerIds <- mapM (insertIfNew . flip DB.PivotalStoryOwner storyId) ownerIds
  return storyId

labelForApp app = "deployed to " ++ lazyByteStringToString app

insertIfNew :: (MonadIO m, PersistEntityBackend val ~ backend, PersistEntity val, PersistUnique backend) => val -> ReaderT backend m (Entity val)
insertIfNew = flip upsert []

parsePostgresConnectionUrl :: String -> String -> String -> String -> String -> BCH.ByteString
parsePostgresConnectionUrl host dbname user password port = BCH.pack $ "host=" ++ host ++ " dbname=" ++ dbname ++ " user=" ++ user ++ " password=" ++ password ++ " port=" ++ port

doubleFmap f = fmap (fmap f)
type ReaderIO = ReaderT Environment IO ()


runReaderIO :: Environment -> ReaderIO -> IO ()
runReaderIO env r = runReaderT r env



main :: IO ()
main =  do
  apiToken <- BCH.pack `liftM` getEnv "PIVOTAL_TRACKER_API_TOKEN"
  connectionString <- liftM5 parsePostgresConnectionUrl (getEnv "DATABASE_HOST") (getEnv "DATABASE_NAME") (getEnv "DATABASE_USER") (getEnv "DATABASE_PASSWORD") (getEnv "DATABASE_PORT")
  runDbIO connectionString (runMigrationUnsafe DB.migrateAll)
  port <- read `liftM` getEnv "PORT"
  slackEndpoint <- getEnv "SLACK_INTEGRATION_ENDPOINT"
  let environment = Environment apiToken slackEndpoint
  WS.scotty port $ do
    WS.middleware $ staticPolicy (noDots >-> addBase "assets")
    WS.get "/" $ WS.file "index.html"

    WS.post "/deploys" $ do
       gitLog <- WS.param "git_log"
       app    <- WS.param "app"
       liftIO $ labelStories (labelForApp app) environment gitLog
       WS.html . mconcat $ ["<h1>" , (T.pack $ lazyByteStringToString gitLog) , " </h1>" , "<h2>" , (T.pack $ lazyByteStringToString app) , "</h2>"]

    WS.get "/releases/:id" $ do
      id <- WS.param "id"
      release <- liftIO $ runDbIO connectionString (getRelease . toSqlKey . fromIntegral $ read id)
      WS.json release

    WS.get "/releases" $ do
      releases <- liftIO $ runDbIO connectionString getReleases
      WS.json releases

    WS.post "/releases" $ do
       gitLog <- WS.param "git_log"
       app    <- WS.param "app"
       liftIO $ flip runReaderT environment $ do
         stories <- getStories gitLog
         updateLabelsOnStories (labelForApp app) $ map story stories
         liftIO $ runDbIO connectionString$ do
           pivotalStoryIds <- mapM insertPivotalStory stories
           time <- liftIO getCurrentTime
           releaseId <- insert $ DB.Release time (Just . LT.toStrict . LT.pack $ lazyByteStringToString gitLog)
           let releaseStories = map (getReleaseStory releaseId) pivotalStoryIds
           liftIO . (notifyNewRelease slackEndpoint) . DT.pack . show . unSqlBackendKey $ DB.unReleaseKey releaseId
           mapM_ insertIfNew releaseStories
       WS.html "Success!"
