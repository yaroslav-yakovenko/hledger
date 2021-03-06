{-# LANGUAGE OverloadedStrings, RecordWildCards, FlexibleInstances #-}
{-|

An account-centric transactions report.

-}

module Hledger.Reports.AccountTransactionsReport (
  AccountTransactionsReport,
  AccountTransactionsReportItem,
  accountTransactionsReport,
  accountTransactionsReportItems,
  transactionRegisterDate,
  tests_AccountTransactionsReport
)
where

import Data.List
import Data.Ord
import Data.Maybe
import qualified Data.Text as T
import Data.Time.Calendar

import Hledger.Data
import Hledger.Query
import Hledger.Reports.ReportOptions
import Hledger.Utils


-- | An account transactions report represents transactions affecting
-- a particular account (or possibly several accounts, but we don't
-- use that). It is used eg by hledger-ui's and hledger-web's register
-- view, and hledger's aregister report, where we want to show one row
-- per transaction, in the context of the current account. Report
-- items consist of:
--
-- - the transaction, unmodified
--
-- - the transaction as seen in the context of the current account and query,
--   which means:
--
--   - the transaction date is set to the "transaction context date",
--     which can be different from the transaction's general date:
--     if postings to the current account (and matched by the report query)
--     have their own dates, it's the earliest of these dates.
--
--   - the transaction's postings are filtered, excluding any which are not
--     matched by the report query
--
-- - a text description of the other account(s) posted to/from
--
-- - a flag indicating whether there's more than one other account involved
--
-- - the total increase/decrease to the current account
--
-- - the report transactions' running total after this transaction;
--   or if historical balance is requested (-H), the historical running total.
--   The historical running total includes transactions from before the
--   report start date if one is specified, filtered by the report query.
--   The historical running total may or may not be the account's historical
--   running balance, depending on the report query.
--
-- Items are sorted by transaction register date (the earliest date the transaction
-- posts to the current account), most recent first.
-- Reporting intervals are currently ignored.
--
type AccountTransactionsReport =
  (String                          -- label for the balance column, eg "balance" or "total"
  ,[AccountTransactionsReportItem] -- line items, one per transaction
  )

type AccountTransactionsReportItem =
  (
   Transaction -- the transaction, unmodified
  ,Transaction -- the transaction, as seen from the current account
  ,Bool        -- is this a split (more than one posting to other accounts) ?
  ,String      -- a display string describing the other account(s), if any
  ,MixedAmount -- the amount posted to the current account(s) (or total amount posted)
  ,MixedAmount -- the register's running total or the current account(s)'s historical balance, after this transaction
  )

totallabel   = "Period Total"
balancelabel = "Historical Total"

accountTransactionsReport :: ReportOpts -> Journal -> Query -> Query -> AccountTransactionsReport
accountTransactionsReport ropts j reportq thisacctq = (label, items)
  where
    -- a depth limit should not affect the account transactions report
    -- seems unnecessary for some reason XXX
    reportq' = -- filterQuery (not . queryIsDepth)
               reportq

    -- get all transactions
    ts1 =
      -- ptraceAtWith 5 (("ts1:\n"++).pshowTransactions) $
      jtxns j

    -- apply any cur:SYM filters in reportq'
    symq  = filterQuery queryIsSym reportq'
    ts2 =
      ptraceAtWith 5 (("ts2:\n"++).pshowTransactions) $
      (if queryIsNull symq then id else map (filterTransactionAmounts symq)) ts1

    -- keep just the transactions affecting this account (via possibly realness or status-filtered postings)
    realq = filterQuery queryIsReal reportq'
    statusq = filterQuery queryIsStatus reportq'
    ts3 =
      traceAt 3 ("thisacctq: "++show thisacctq) $
      ptraceAtWith 5 (("ts3:\n"++).pshowTransactions) $
      filter (matchesTransaction thisacctq . filterTransactionPostings (And [realq, statusq])) ts2

    -- maybe convert these transactions to cost or value
    -- PARTIAL:
    prices = journalPriceOracle (infer_value_ ropts) j
    styles = journalCommodityStyles j
    periodlast =
      fromMaybe (error' "journalApplyValuation: expected a non-empty journal") $ -- XXX shouldn't happen
      reportPeriodOrJournalLastDay ropts j
    mreportlast = reportPeriodLastDay ropts
    today = fromMaybe (error' "journalApplyValuation: could not pick a valuation date, ReportOpts today_ is unset") $ today_ ropts -- XXX shouldn't happen
    multiperiod = interval_ ropts /= NoInterval
    tval = case value_ ropts of
             Just v  -> \t -> transactionApplyValuation prices styles periodlast mreportlast today multiperiod t v
             Nothing -> id
    ts4 =
      ptraceAtWith 5 (("ts4:\n"++).pshowTransactions) $
      map tval ts3 

    -- sort by the transaction's register date, for accurate starting balance
    -- these are not yet filtered by tdate, we want to search them all for priorps
    ts5 =
      ptraceAtWith 5 (("ts5:\n"++).pshowTransactions) $
      sortBy (comparing (transactionRegisterDate reportq' thisacctq)) ts4

    (startbal,label)
      | balancetype_ ropts == HistoricalBalance = (sumPostings priorps, balancelabel)
      | otherwise                               = (nullmixedamt,        totallabel)
      where
        priorps = dbg5 "priorps" $
                  filter (matchesPosting
                          (dbg5 "priorq" $
                           And [thisacctq, tostartdateq, datelessreportq]))
                         $ transactionsPostings ts5
        tostartdateq =
          case mstartdate of
            Just _  -> Date (DateSpan Nothing mstartdate)
            Nothing -> None  -- no start date specified, there are no prior postings
        mstartdate = queryStartDate (date2_ ropts) reportq'
        datelessreportq = filterQuery (not . queryIsDateOrDate2) reportq'

    -- accountTransactionsReportItem will keep transactions of any date which have any posting inside the report period.
    -- Should we also require that transaction date is inside the report period ?
    -- Should we be filtering by reportq here to apply other query terms (?)
    -- Make it an option for now.
    filtertxns = txn_dates_ ropts

    items = reverse $
            accountTransactionsReportItems reportq' thisacctq startbal negate $
            (if filtertxns then filter (reportq' `matchesTransaction`) else id) $
            ts5

pshowTransactions :: [Transaction] -> String
pshowTransactions = pshow . map (\t -> unwords [show $ tdate t, T.unpack $ tdescription t])

-- | Generate transactions report items from a list of transactions,
-- using the provided user-specified report query, a query specifying
-- which account to use as the focus, a starting balance, a sign-setting
-- function and a balance-summing function. Or with a None current account
-- query, this can also be used for the transactionsReport.
accountTransactionsReportItems :: Query -> Query -> MixedAmount -> (MixedAmount -> MixedAmount) -> [Transaction] -> [AccountTransactionsReportItem]
accountTransactionsReportItems reportq thisacctq bal signfn =
    catMaybes . snd .
    mapAccumL (accountTransactionsReportItem reportq thisacctq signfn) bal

accountTransactionsReportItem :: Query -> Query -> (MixedAmount -> MixedAmount) -> MixedAmount -> Transaction -> (MixedAmount, Maybe AccountTransactionsReportItem)
accountTransactionsReportItem reportq thisacctq signfn bal torig = balItem
    -- 201403: This is used for both accountTransactionsReport and transactionsReport, which makes it a bit overcomplicated
    -- 201407: I've lost my grip on this, let's just hope for the best
    -- 201606: we now calculate change and balance from filtered postings, check this still works well for all callers XXX
    where
      tfiltered@Transaction{tpostings=reportps} = filterTransactionPostings reportq torig
      tacct = tfiltered{tdate=transactionRegisterDate reportq thisacctq tfiltered}
      balItem = case reportps of
           [] -> (bal, Nothing)  -- no matched postings in this transaction, skip it
           _  -> (b, Just (torig, tacct, numotheraccts > 1, otheracctstr, a, b))
                 where
                  (thisacctps, otheracctps) = partition (matchesPosting thisacctq) reportps
                  numotheraccts = length $ nub $ map paccount otheracctps
                  otheracctstr | thisacctq == None  = summarisePostingAccounts reportps     -- no current account ? summarise all matched postings
                               | numotheraccts == 0 = summarisePostingAccounts thisacctps   -- only postings to current account ? summarise those
                               | otherwise          = summarisePostingAccounts otheracctps  -- summarise matched postings to other account(s)
                  a = signfn $ negate $ sum $ map pamount thisacctps
                  b = bal + a

-- | What is the transaction's date in the context of a particular account
-- (specified with a query) and report query, as in an account register ?
-- It's normally the transaction's general date, but if any posting(s)
-- matched by the report query and affecting the matched account(s) have
-- their own earlier dates, it's the earliest of these dates.
-- Secondary transaction/posting dates are ignored.
transactionRegisterDate :: Query -> Query -> Transaction -> Day
transactionRegisterDate reportq thisacctq t
  | null thisacctps = tdate t
  | otherwise       = minimum $ map postingDate thisacctps
  where
    reportps   = tpostings $ filterTransactionPostings reportq t
    thisacctps = filter (matchesPosting thisacctq) reportps

-- -- | Generate a short readable summary of some postings, like
-- -- "from (negatives) to (positives)".
-- summarisePostings :: [Posting] -> String
-- summarisePostings ps =
--     case (summarisePostingAccounts froms, summarisePostingAccounts tos) of
--        ("",t) -> "to "++t
--        (f,"") -> "from "++f
--        (f,t)  -> "from "++f++" to "++t
--     where
--       (froms,tos) = partition (fromMaybe False . isNegativeMixedAmount . pamount) ps

-- | Generate a simplified summary of some postings' accounts.
-- To reduce noise, if there are both real and virtual postings, show only the real ones.
summarisePostingAccounts :: [Posting] -> String
summarisePostingAccounts ps =
  (intercalate ", " . map (T.unpack . accountSummarisedName) . nub . map paccount) displayps -- XXX pack
  where
    realps = filter isReal ps
    displayps | null realps = ps
              | otherwise   = realps

-- tests

tests_AccountTransactionsReport = tests "AccountTransactionsReport" [
 ]
