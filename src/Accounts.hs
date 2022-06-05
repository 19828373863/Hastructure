{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Accounts (Account(..),ReserveAmount(..),draw,deposit)
    where
import qualified Data.Time as T
import Lib (Period(Monthly),Rate,Balance,Dates,StartDate,EndDate,LastIntPayDate
           ,DayCount(ACT_365),calcInt
           ,DealStats,Statement(..),appendStmt,Txn(..))

import           Data.Aeson       hiding (json)
import Language.Haskell.TH
import Data.Aeson.TH
import Data.Aeson.Types

data InterestInfo = BankAccount Rate Period
                   deriving (Show)

data ReserveAmount = PctReserve  DealStats Rate
                   | FixReserve  Float
                   | Max ReserveAmount ReserveAmount
                   deriving (Show)


--data Statement = Statement {
--    stmtDate     ::Dates
--    ,stmtBalance ::[Balance]
--    ,stmtAmt     ::[Float]
--    ,stmtMemo    ::[String]
--} deriving (Show)

data Account = Account {
    accBalance :: Float
    ,accName :: String
    ,accInterest :: Maybe InterestInfo
    ,accType :: Maybe ReserveAmount
    ,accStmt :: Maybe Statement
} deriving (Show)

$(deriveJSON defaultOptions ''InterestInfo)
$(deriveJSON defaultOptions ''ReserveAmount)
$(deriveJSON defaultOptions ''Account)

depositInt :: Account -> StartDate -> EndDate -> Account
depositInt acc@(Account
                bal
                _
                (Just (BankAccount r _) )
                _
                stmt)
                sd
                ed =
  acc {accBalance = newBal,accStmt = (Just newStmt)}
  where
    newBal = (accured_int + bal)
    accured_int =  calcInt bal sd ed r ACT_365
    newStmt = appendStmt stmt (AccTxn ed newBal accured_int "Deposit Int")

transfer :: Account -> Float -> T.Day -> Account -> (Account, Account)
transfer source_acc@(Account s_bal _ _ _ s_stmt)
         amount
         d
         target_acc@(Account t_bal _ _ _ t_stmt)
  = (source_acc {accBalance = new_s_bal, accStmt = (Just source_newStmt)}
    ,target_acc {accBalance = new_t_bal, accStmt = (Just target_newStmt)})
  where
    new_s_bal = s_bal - amount
    new_t_bal = t_bal + amount
    source_newStmt = appendStmt s_stmt (AccTxn d (- amount) new_s_bal "Transfer out")
    target_newStmt = appendStmt t_stmt (AccTxn d amount new_t_bal "Transfer in")

deposit :: Float -> T.Day -> String -> Account -> Account
deposit amount d source acc@(Account bal _ _ _ maybeStmt)  =
    acc {accBalance = newBal, accStmt = Just newStmt}
  where
    newBal = bal + amount
    newStmt = appendStmt maybeStmt (AccTxn d amount newBal source)

draw :: Float -> T.Day -> String -> Account -> Account
draw amount d source acc = deposit (- amount) d source acc

getAvailBal :: Account -> Float
getAvailBal a = (accBalance a)
