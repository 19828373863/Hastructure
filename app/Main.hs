{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
module Main where

import           Data.Aeson       hiding (json)
import           Data.Monoid      ((<>))
import           Data.Text        (Text, pack)
import           GHC.Generics
import qualified Deal as D
import qualified Asset as P
import qualified Assumptions as AP
import Data.ByteString.Lazy.Char8 (unpack)

import Data.Aeson hiding (json)
import Language.Haskell.TH
import Data.Aeson.TH
import Data.Aeson.Types

import Yesod
import Network.Wai
import Network.Wai.Handler.Warp
import Network.HTTP.Types
import Network.Wai.Middleware.Cors
-- import Network.Wai.Middleware.Cors

data RunDealReq = RunDealReq {
  deal :: D.TestDeal
  ,assump :: Maybe [AP.AssumptionBuilder]
}
$(deriveJSON defaultOptions ''RunDealReq)

-- type Api = SpockM () () () ()
-- type ApiAction a = SpockAction () () () a


data App = App

mkYesod "App" [parseRoutes|
 /run_deal2 RunDealR POST OPTIONS
 /version VersionR GET
|]

instance Yesod App where
  yesodMiddleware = defaultYesodMiddleware

postRunDealR :: Handler  Value -- D.TestDeal
postRunDealR =  do
  runReq <- requireCheckJsonBody :: Handler RunDealReq
  returnJson $ D.runDeal (deal runReq) D.DealPoolFlow (assump runReq)

optionsRunDealR :: Handler String -- D.TestDeal
optionsRunDealR = do
  addHeader "Access-Control-Allow-Origin" "*"
  addHeader "Access-Control-Allow-Methods" "OPTIONS"
  return "Good"

getVersionR :: Handler String
getVersionR =  do
  addHeader "Access-Control-Allow-Origin" "*"
  addHeader "Access-Control-Allow-Methods" "GET"
  return "{\"version\":\"0.0.1\"}"

  -- returnJson $

main :: IO ()
main =
  -- warp 8081 App
  do
   app <- toWaiApp App
   run 8081 $ defaultMiddlewaresNoLogging $ cors (const $ Just $ simpleCorsResourcePolicy { corsOrigins = Nothing , corsMethods = ["OPTIONS", "GET", "PUT", "POST"] , corsRequestHeaders = simpleHeaders }) $ app
            -- $ simpleCors app
-- main = toWaiApp 8081 App
--  spockCfg <- defaultSpockCfg () PCNoDatabase ()
--  runSpock 8081 (spock spockCfg app)

--app :: Api
--app = do
--  get "info" $ do
--    setHeader "Access-Control-Allow-Headers" "Content-Type"
--    text "{\"version\":\"0.0.1\"}"

--  post "run_deal2" $ do
--    theRunReq <- jsonBody' :: ApiAction RunDealReq
--    setHeader "Access-Control-Allow-Origin" "*"
--    setHeader "Access-Control-Allow-Headers" "Content-Type"
--    setHeader "Access-Control-Allow-Methods" "*"
--    text $ pack $ unpack  $ encode (D.runDeal (deal theRunReq) D.DealPoolFlow (assump theRunReq))

--  hookRoute OPTIONS "run_deal2" $ do
--    setHeader "Access-Control-Allow-Origin" "*"
--    setHeader "Access-Control-Allow-Headers" "*"
--    setHeader "Access-Control-Allow-Methods" "*"
--    text "good"
--
