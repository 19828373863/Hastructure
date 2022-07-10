{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TemplateHaskell #-}

module Liability
  (Bond(..),BondType(..),OriginalInfo(..),SinkFundSchedule(..)
  ,InterestInfo(..),payInt,payPrin,consolTxn,consolStmt,backoutDueIntByYield)
  where

import Language.Haskell.TH
import           Data.Aeson       hiding (json)
import           Data.Aeson.TH
import Lib (Period,Floor,Cap,getValByDate)

import qualified Data.Time as T
import Lib (Balance,Rate,Spread,Index(..),Dates,calcInt,DayCount(..)
           ,Txn(..),combineTxn,Statement(..),appendStmt,Period(..),Ts(..)
           ,TsPoint(..),getTxnDate,getTxnAmt)
import Data.List (findIndex,zip6)

import Debug.Trace
debug = flip trace


data InterestInfo = 
          Floater Index Spread Rate Period (Maybe Floor) (Maybe Cap)
          | Fix Rate
          deriving (Show)

data OriginalInfo = OriginalInfo {
  originBalance::Float
  ,originDate::T.Day
  ,originRate::Float
} deriving (Show)

type SinkFundSchedule = Ts
type PlannedAmorSchedule = Ts

data BondType = Sequential
                | SinkFund SinkFundSchedule
                | PAC PlannedAmorSchedule
                | PAC_Anchor PlannedAmorSchedule [String]
                | Lockout T.Day
                | Z
                | InterestByYield Float
                deriving (Show)

data Bond = Bond {
  bndName :: String
  ,bndType :: BondType
  ,bndOriginInfo :: OriginalInfo
  ,bndInterestInfo :: InterestInfo
  ,bndBalance :: Balance
  ,bndRate :: Float
  ,bndDuePrin :: Float
  ,bndDueInt :: Float
  ,bndLastIntPay :: Maybe T.Day
  ,bndLastPrinPay :: Maybe T.Day
  ,bndStmt :: Maybe Statement
} deriving (Show)

consolTxn :: [Txn] -> Txn -> [Txn]
consolTxn (txn:txns) txn0
  = if txn==txn0 then 
     (combineTxn txn txn0):txns
    else
     txn0:txn:txns 
consolTxn [] txn = [txn]

consolStmt :: Bond -> Bond
consolStmt b@Bond{bndStmt = Just (Statement (txn:txns))}
  =  b {bndStmt = Just (Statement (reverse (foldl consolTxn [txn] txns)  ))}

consolStmt b@Bond{bndStmt = Nothing} =  b {bndStmt = Nothing}

payInt :: T.Day -> Float -> Bond -> Bond
payInt d amt bnd@(Bond bn bt oi iinfo bal r duePrin dueInt lpayInt lpayPrin stmt) =
  Bond bn bt oi iinfo bal r duePrin new_due (Just d) lpayPrin (Just new_stmt)
  where
    new_due = dueInt - amt
    new_stmt = appendStmt stmt (BondTxn d bal amt 0 r amt "INT PAY")

payPrin :: T.Day -> Float -> Bond -> Bond
payPrin d amt bnd@(Bond bn bt oi iinfo bal r duePrin dueInt lpayInt lpayPrin stmt) =
  Bond bn bt oi iinfo new_bal r new_due dueInt lpayInt (Just d) (Just new_stmt)
  where
    new_bal = bal - amt
    new_due = duePrin - amt
    new_stmt = appendStmt stmt (BondTxn d new_bal 0 amt 0 amt "PRIN PAY")


type Valuation = Float
type WAL = Float
type Duration = Float
type Yield = Float

data PriceResult = PriceResult Valuation -- WAL Duration-- valuation,wal,accu,duration
data YieldResult = Yield

pv :: Ts -> T.Day -> T.Day -> Float -> Float
pv rc today d amt = 
    amt / (1+discount_rate)^(div distance 365)
    where
        discount_rate = getValByDate rc d
        distance = fromIntegral (T.diffDays d today)

priceBond :: T.Day -> Ts -> Bond -> PriceResult
priceBond d rc b@(Bond _ _ _ _ _ _ _ _ _ _ (Just (Statement txns)))
  = PriceResult $ sum $ map (\x -> (pv rc d (getTxnDate x) (getTxnAmt x))) txns

priceBond d rc b@(Bond _ _ _ _ _ _ _ _ _ _ Nothing ) = PriceResult 0

type IRR = Float
type InitBalance = Float

_calcIRR :: InitBalance -> IRR -> T.Day -> Ts -> IRR
_calcIRR amt initIrr today (AmountCurve cashflows)
   = if abs(diff) < 0.005 then
       initIrr
     else
       _calcIRR amt nextIrr today (AmountCurve cashflows)
     where
       discount (TsPoint _d _a) _r =  _a / ((1+_r)^(div (fromIntegral (T.diffDays _d today)) 365))
       pv = foldr (\_ts acc -> (discount _ts initIrr) + acc) 0 cashflows
       diff = pv - amt
       nextIrr = if diff > 0 then
                   initIrr * 1.05
                 else
                   initIrr * 0.95

calcBondYield :: T.Day -> Float ->  Bond -> Float
calcBondYield d cost b@(Bond _ _ _ _ _ _ _ _ _ _ (Just (Statement txns)))
 =  _calcIRR cost 0.05 d (AmountCurve cashflows)
   where
     cashflows = [ TsPoint (getTxnDate txn) (getTxnAmt txn)  | txn <- txns ]

calcBondYield _ _ (Bond _ _ _ _ _ _ _ _ _ _ Nothing) = 0

backoutDueIntByYield :: T.Day -> Bond -> Float -> Float
backoutDueIntByYield d b@(Bond _ (InterestByYield y) (OriginalInfo obal odate _)
                           _ currentBalance _ _ _ _ _ (Just (Statement txns)))
                       initAmt
  = if abs(diff_irr) < 0.000001 then
        initAmt
    else
        backoutDueIntByYield d b nextAmount -- `debug` ("NextAmt=>"++show(nextAmount))
    where
     nextAmount = if diff_irr > 0 then
                       initAmt * 1.03
                    else
                       initAmt * 0.97
     diff_irr = y - _irr
     _irr = _calcIRR obal y odate (AmountCurve (cashflows++[(TsPoint d initAmt)]))
     cashflows = [ TsPoint (getTxnDate txn) (getTxnAmt txn)  | txn <- txns ]

tb1 =   (Bond "A"
      (InterestByYield 0.02)
      (OriginalInfo 200 (T.fromGregorian 2018 1 1) 0.0)
      (Fix 0.0)
       150 0.0 0.0 0.0 Nothing Nothing
       (Just (Statement [(BondTxn (T.fromGregorian 2019 1 1) 0 0 0 0 80 ""),(BondTxn (T.fromGregorian 2020 1 1) 0 0 0 0 20 "")]))
       )


$(deriveJSON defaultOptions ''InterestInfo)
$(deriveJSON defaultOptions ''OriginalInfo)
$(deriveJSON defaultOptions ''BondType)
$(deriveJSON defaultOptions ''Bond)
