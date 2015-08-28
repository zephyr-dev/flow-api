{-# LANGUAGE EmptyDataDecls       #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE QuasiQuotes          #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE MultiParamTypeClasses#-}
{-# LANGUAGE GeneralizedNewtypeDeriving#-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Migrations where
import Database.Persist.TH
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Release
  createdAt UTCTime
  deriving Show

ReleaseStory
  releaseId ReleaseId
  pivotalStoryId PivotalStoryId
  UniqueReleaseStoryCommit releaseId pivotalStoryId
  deriving Show

PivotalStory
  projectId Int
  trackerId T.Text
  name T.Text
  description T.Text
  deriving Show
|]
