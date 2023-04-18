{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TemplateHaskell       #-}
module Server where 

import Prelude ()
import Prelude.Compat
import System.Environment

import Control.Monad.Except
import Control.Monad.Reader
import Control.Lens
import Data.Aeson
import Data.Aeson.Types
import Data.Aeson.TH
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Attoparsec.ByteString
import Data.ByteString (ByteString)
import Data.List
import Data.Maybe
import qualified Data.Map as Map
import Data.String.Conversions
import Data.Time.Calendar
import GHC.Generics
import qualified Data.ByteString.Lazy.Char8 as BL8
import Lucid
import Network.Wai
import Network.Wai.Handler.Warp
import qualified Data.Aeson.Parser
import Language.Haskell.TH

import Data.OpenApi hiding(Server) 
import Servant.OpenApi
import Servant
import Servant.Types.SourceT (source)

import Types 
import qualified Deal as D
import qualified Asset as P
import qualified AssetClass.Installment as AC_Installment
import qualified AssetClass.Mortgage as AC_Mortgage
import qualified AssetClass.Loan as AC_Loan
import qualified AssetClass.Lease as AC_Lease
import qualified Assumptions as AP
import qualified Cashflow as CF
import qualified Liability as L


data Version = Version 
  { version :: String 
  } deriving (Eq, Show, Generic)

$(deriveJSON defaultOptions ''Version)
instance ToSchema Version

version1 :: Version 
version1 = Version "0.13.0"

data PoolType = MPool (P.Pool AC_Mortgage.Mortgage)
              | LPool (P.Pool AC_Loan.Loan)
              | IPool (P.Pool AC_Installment.Installment)
              | RPool (P.Pool AC_Lease.Lease)
              deriving(Show, Generic)

instance ToSchema PoolType
$(deriveJSON defaultOptions ''PoolType)

data DealType = MDeal (D.TestDeal AC_Mortgage.Mortgage)
              | LDeal (D.TestDeal AC_Loan.Loan)
              | IDeal (D.TestDeal AC_Installment.Installment) 
              | RDeal (D.TestDeal AC_Lease.Lease) 
              deriving(Show, Generic)

instance ToParamSchema DealType
instance ToSchema AP.ApplyAssumptionType
instance ToSchema AP.BondPricingInput
instance ToSchema DealType

$(deriveJSON defaultOptions ''DealType)

type RunResp = (DealType , Maybe CF.CashFlowFrame, Maybe [ResultComponent],Maybe (Map.Map String L.PriceResult))

wrapRun :: DealType -> Maybe AP.ApplyAssumptionType -> Maybe AP.BondPricingInput -> RunResp
wrapRun (MDeal d) mAssump mPricing = let 
					(_d,_pflow,_rs,_p) = D.runDeal d D.DealPoolFlowPricing mAssump mPricing
				     in 
                                    	(MDeal _d,_pflow,_rs,_p)
wrapRun (RDeal d) mAssump mPricing = let 
					(_d,_pflow,_rs,_p) = D.runDeal d D.DealPoolFlowPricing mAssump mPricing
				     in 
                                    	(RDeal _d,_pflow,_rs,_p)
wrapRun (IDeal d) mAssump mPricing = let 
					(_d,_pflow,_rs,_p) = D.runDeal d D.DealPoolFlowPricing mAssump mPricing
				     in 
                                    	(IDeal _d,_pflow,_rs,_p)
wrapRun (LDeal d) mAssump mPricing = let 
					(_d,_pflow,_rs,_p) = D.runDeal d D.DealPoolFlowPricing mAssump mPricing
				     in 
                                    	(LDeal _d,_pflow,_rs,_p)

wrapRunPool :: PoolType -> Maybe AP.ApplyAssumptionType -> [CF.CashFlowFrame]
wrapRunPool pt assump = case pt of 
                          MPool p -> D.runPool2 p assump
                          LPool p -> D.runPool2 p assump
                          IPool p -> D.runPool2 p assump
                          RPool p -> D.runPool2 p assump


type ScenarioName = String
data RunDealReq = SingleRunReq DealType (Maybe AP.ApplyAssumptionType) (Maybe AP.BondPricingInput)
	 	|MultiScenarioRunReq DealType (Map.Map ScenarioName AP.ApplyAssumptionType) (Maybe AP.BondPricingInput)
		|MultiDealRunReq (Map.Map ScenarioName DealType) (Maybe AP.ApplyAssumptionType) (Maybe AP.BondPricingInput)
              deriving(Show, Generic)

instance ToSchema RunDealReq
data RunPoolReq = SingleRunPoolReq PoolType (Maybe AP.ApplyAssumptionType)
		| MultiScenarioRunPoolReq PoolType (Map.Map ScenarioName AP.ApplyAssumptionType)
              deriving(Show, Generic)

instance ToSchema RunPoolReq
$(deriveJSON defaultOptions ''RunDealReq)
$(deriveJSON defaultOptions ''RunPoolReq)

type EngineAPI = "version"  :> Get '[JSON] Version
            :<|> "runPool" :> ReqBody '[JSON] RunPoolReq :> Post '[JSON] [CF.CashFlowFrame]
            :<|> "runPoolByScenarios" :> ReqBody '[JSON] RunPoolReq :> Post '[JSON] (Map.Map ScenarioName [CF.CashFlowFrame])
            :<|> "runDeal" :> ReqBody '[JSON] RunDealReq :> Post '[JSON] RunResp
            :<|> "runDealByScenarios" :> ReqBody '[JSON] RunDealReq :> Post '[JSON] (Map.Map ScenarioName RunResp)
            :<|> "runMultiDeals" :> ReqBody '[JSON] RunDealReq :> Post '[JSON] (Map.Map ScenarioName RunResp)


server1 :: Server EngineAPI
server1 =  showVersion
      :<|> runPool
      :<|> runPoolScenarios
      :<|> runDeal
      :<|> runDealScenarios
      :<|> runMultiDeals
    where 
        showVersion = return version1
        runPool (SingleRunPoolReq pt passumption) 
          = return $ wrapRunPool pt passumption
	runPoolScenarios (MultiScenarioRunPoolReq pt mAssumps) 
	  = return $ Map.map (wrapRunPool pt . Just) mAssumps
        runDeal (SingleRunReq dt assump pricing) = return $ wrapRun dt assump pricing
	runDealScenarios (MultiScenarioRunReq dt mAssumps pricing) 
		= return $ Map.map (\singleAssump -> wrapRun dt (Just singleAssump) pricing) mAssumps
	runMultiDeals (MultiDealRunReq mDts assump pricing) 
		= return $ Map.map (\singleDealType -> wrapRun singleDealType assump pricing) mDts
                



engineAPI :: Proxy EngineAPI
engineAPI = Proxy

app1 :: Application
app1 = serve engineAPI server1

-- Swagger API
type SwaggerAPI = "swagger.json" :> Get '[JSON] OpenApi
type API = SwaggerAPI :<|> EngineAPI

-- todo swagger 
todoSwagger :: OpenApi
todoSwagger = toOpenApi engineAPI
  & info.title .~ "todo API"
  & info.description ?~ "api descript"
  & info.license ?~ ("MIT")



server2 :: Server API
server2 = return todoSwagger :<|> error "not implemented"

app2 :: Application
app2 = serve (Proxy :: Proxy API) server2

writeSwaggerJSON :: IO ()
writeSwaggerJSON = BL8.writeFile "swagger.json" (encodePretty todoSwagger)



main :: IO ()
-- main = run 8010 app1
main = run 8010 app2
