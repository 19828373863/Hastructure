{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Assumptions (AssumptionBuilder(..),BondPricingInput(..),toPeriodRateByInterval
                    ,AssumptionInput(..))

 where

import Call as C
import Lib (Rate,Index(..),Ts(..),TsPoint(..),toDate)
import qualified Data.Map as Map 
import Data.List
import Data.Aeson hiding (json)
import Language.Haskell.TH
import Data.Aeson.TH
import Data.Aeson.Types
import qualified Data.Time as T


type AssumptionLists = [AssumptionBuilder]

data AssumptionInput = Single AssumptionLists
                     | Multiple [AssumptionLists]
                     deriving (Show)

data AssumptionBuilder = MortgageByAge ([Int],[Float])
                | MortgageByRate ([Float],[Float])
                | PrepaymentConstant Float
                | PrepaymentCPR Float
                | PrepaymentCPRCurve [Float]     -- this will ignore the payment interval
                | PrepaymentDistribution Float [Float] -- total default rate, distribution pct
                | DefaultConstant Float
                | DefaultCDR Float
                | DefaultDistribution Float [Float] -- total default rate, distribution pct
                | Recovery (Rate,Int)
                | LinearTo Int Float
                | InterestRateConstant Index Float
                | InterestRateCurve Index [(T.Day,Float)]
                | PrepaymentByAging [(Int,Float)]
                | CallWhen [C.CallOption]
                | StopRunBy T.Day
                | EvenRecoveryOnDefault Float Int
                deriving (Show)

-- getAssumption :: [AssumptionBuilder] -> AssumptionBuilder

data BondPricingInput = DiscountCurve T.Day Ts
                deriving (Show)

toPeriodRateByInterval :: Float -> Int -> Float
toPeriodRateByInterval annualRate days
  = 1 - (1-annualRate) ** ((fromIntegral days)/365)

$(deriveJSON defaultOptions ''AssumptionBuilder)
$(deriveJSON defaultOptions ''BondPricingInput)
$(deriveJSON defaultOptions ''AssumptionInput)
