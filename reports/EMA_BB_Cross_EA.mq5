//+------------------------------------------------------------------+
//| EMA_BB_Cross_EA.mq5                                              |
//| EMA crosses Bollinger middle line -> buy/sell, real SL/TP on the |
//| order itself (broker-enforced). Runs M30, M15, M5, H4            |
//| independently (own magic/lot/TP/SL each), plus a standalone      |
//| Asia session range sub-strategy. M5 enters INSTANT (market)      |
//| on cross. M15/M30/H4 are buy-only: an up-cross places a near     |
//| buy-limit once price has run past the cross point, a down-cross |
//| places a buy-limit at an approx fib-support offset. Each TF has  |
//| its own block-up/block-down switch to skip trades against trend.|
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

// --- shared engine settings ---
input int    InpDeviation   = 100;   // max slippage, points
input int    InpEmaPeriod   = 14;    // EMA period
input int    InpBbPeriod    = 20;    // BB period
input double InpBbDeviation = 2.0;   // BB deviation
input double InpRatchetBaseLot = 0.01; // base lot all USD inputs (TP/SL, ratchet, etc) are tuned at; scales automatically with InpLots
input double InpTrailTpRatio = 0.9;  // TP slide per $1 SL slide, M30/M15/H4 trail

input group "=== M5 ==="
input bool   InpEnabled_M5        = true;
input string InpTradeHours_M5     = "";
input double InpLots_M5           = 0.01;
input double InpTP_M5             = 9.0;   // price distance (NOT USD -- direct points on the symbol). Validated best on 2024-2026 backtest.
input double InpSL_M5             = 5.0;   // price distance (NOT USD -- direct points on the symbol). Validated best on 2024-2026 backtest.
input int    InpMaxOrders_M5      = 0;
input ulong  InpMagic_M5          = 100304;
input int    InpCooldownBars_M5   = 0;
input bool   InpBlockCrossUp_M5   = false;
input bool   InpBlockCrossDown_M5 = false;
input int    InpMinuteFilterBuy_M5  = -1;  // only take M5 buy-cross if bar's minute-of-hour == this (-1 = disabled)
input int    InpMinuteFilterSell_M5 = -1;  // only take M5 sell-cross if bar's minute-of-hour == this (-1 = disabled)
input double InpHardTimeStopHours_M5 = 0;  // force-close M5 positions held longer than this many hours (0 = disabled)
input bool   InpReverseSignal_M5 = false;  // trade opposite direction of the EMA/BB cross (fade it)
input bool   InpUseTrendFilter_M5 = false; // only take M5 cross in the direction of the H4 EMA (reuses hEmaH4)
input bool   InpUsePreCross_M5 = false;    // enter on predicted (pre-confirmed) cross instead of confirmed cross
input double InpPreCrossGapMax_M5 = 0.05;  // pre-cross: max |ema-mid| raw price gap to consider "imminent"
input bool   InpPreCrossRequireShrink_M5 = true; // pre-cross: require the gap to be shrinking vs prior bar
input int    InpSwingLookback_M5 = 20;     // bars to look back for nearest swing high/low (real wicks)

input group "=== M1/M5 ratchet trail (shared, USD @ base lot) ==="
input bool   InpUseRatchetTrail = true; // false = SL/TP stay at their initial open values, no ratchet trailing at all
// WARNING: InpRatchetStepSL MUST be > 0 -- if 0 or negative, the ratchet while-loop in
// TrailStopsRatchet() never advances and hangs forever (freezes the EA/terminal). Checked
// and blocked in OnInit(); do not set it to 0 or negative.
input double InpRatchetArm     = 1.5;  // profit that arms the trail
input double InpRatchetS1End   = 3.0;  // profit ceiling of stage 1
input double InpRatchetS1TP    = 5.0;  // flat TP during stage 1
input double InpRatchetS2SL    = 2.0;  // SL at start of stage 2
input double InpRatchetS2TP    = 6.1;  // TP at start of stage 2
input double InpRatchetStep    = 3.0;  // stage-2: ratchet again every time profit runs this far past current SL
input double InpRatchetStepSL  = 1.0;  // stage-2: SL increase per ratchet step. MUST be > 0
input double InpRatchetStepTP  = 0.9;  // stage-2: TP increase per ratchet step

input group "=== M15 ==="
input bool   InpEnabled_M15        = true;
input string InpTradeHours_M15     = "";
input double InpLots_M15           = 0.01;
input double InpTP_M15             = 6.0;   // USD
input double InpSL_M15             = 3.0;   // USD
input ulong  InpMagic_M15          = 100303;
input bool   InpBlockCrossUp_M15   = false; // true = skip near buy-limit on up-cross
input bool   InpBlockCrossDown_M15 = false; // true = skip fib dip-buy on down-cross
input int    InpMaxWaitBars_M15    = 0;     // cancel unfilled M15 buy-limit after this many M15 candles (0 = never)

input group "=== M15/M30 shared ==="
input int    InpMaxOrders     = 4;     // max concurrent positions, applied separately to each (each capped at 4 of its own)
input double InpTrailTrigger  = 3.0;   // USD profit that arms the trailing stop
input double InpTrailLock     = 1.0;   // USD locked in when trailing arms, then trails 1:1

input group "=== M30 ==="
input bool   InpEnabled_M30        = true;
input string InpTradeHours_M30     = "";
input double InpLots_M30           = 0.01;
input double InpTP_M30             = 8.0;   // USD
input double InpSL_M30             = 3.0;   // USD
input ulong  InpMagic_M30          = 100302;
input bool   InpBlockCrossUp_M30   = false;
input bool   InpBlockCrossDown_M30 = false;
input int    InpMaxWaitBars_M30    = 0;     // cancel unfilled M30 buy-limit after this many M30 candles (0 = never)

input group "=== H4 ==="
input bool   InpEnabled_H4        = true;
input string InpTradeHours_H4     = "";
input double InpLots_H4           = 0.01;
input double InpTP_H4             = 80.0;  // USD
input double InpSL_H4             = 60.0;  // USD
input int    InpMaxOrders_H4      = 0;     // 0 = unlimited
input ulong  InpMagic_H4          = 100305;
input double InpTrailTrigger_H4   = 50.0;  // USD profit that arms the trailing stop
input double InpTrailLock_H4      = 20.0;  // USD locked in when trailing arms, then trails 1:1
input bool   InpBlockCrossUp_H4   = false;
input bool   InpBlockCrossDown_H4 = false;
input int    InpMaxWaitBars_H4    = 0;     // cancel unfilled H4 buy-limit after this many H4 candles (0 = never)

// --- M15/M30/H4 buy-limit-on-cross (all three are buy-only) ---
// up-cross (EMA crosses BB mid UP): only chase if price (a) already ran above the cross
// point (x, BB mid at the cross bar) by more than InpCrossGateUp; then buy-limit near price.
// down-cross (EMA crosses BB mid DOWN): no gate -- buy the dip at an approx fib-support offset.
input double InpCrossGateUp       = 5.0;   // USD-equiv: up-cross needs (a-x) > this to fire, else buy-limit at current price
input double InpNearOffset_M15M30 = 5.0;   // USD-equiv buy-limit distance below price, up-cross (gated), M15 & M30
input double InpNearOffset_H4     = 10.0;  // USD-equiv buy-limit distance below price, up-cross (gated), H4
// down-cross: buy-limit at a real fib retracement support -- swingHigh - (swingHigh-swingLow)*ratio,
// swing = highest-high/lowest-low over the last InpFibLookback CLOSED bars of that same timeframe.
// starting at the configured ratio, if the level isn't at least InpFibMinDist_* away from
// current price, step to the next deeper standard ratio (0.236/0.382/0.5/0.618/0.786/1.0)
// until one clears that floor; no trade if even the deepest (swing low itself) doesn't.
input int    InpFibLookback       = 20;    // bars (own TF) used to find the swing high/low
input double InpFibRatio_M15M30   = 0.382; // starting fib ratio, M15 & M30 (38.2% -- shallower pulls on lower TFs)
input double InpFibRatio_H4       = 0.618; // starting fib ratio, H4 (61.8% -- deeper pulls before continuation)
input double InpFibMinDist_M15M30 = 30.0;  // USD-equiv: fib level must be at least this far below price, M15 & M30
input double InpFibMinDist_H4     = 50.0;  // USD-equiv: fib level must be at least this far below price, H4
input double InpFibFloorTolerance = 5.0;   // USD-equiv: if a level misses the floor by no more than this, snap to the floor instead of trying a deeper ratio

// --- Asia session range EA (standalone, own magic, independent of EMA/BB logic above) ---
input bool   InpAsiaEnabled   = true;  // master on/off switch
input int    InpAsiaEndHour   = 8;     // Asia session end, SERVER time (broker clock, same as CSV timestamps) -- verify/adjust when broker shifts DST
input double InpAsiaLots      = 0.01;  // lot size for all Asia-range orders
input double InpAsiaSL        = 5.0;   // USD stop loss, at InpRatchetBaseLot
input double InpAsiaTP        = 10.0;  // USD take profit for the "at avg" extreme-zone entries, at InpRatchetBaseLot
input double InpAsiaZoneOuter = 25.0;  // USD-equivalent distance from avg marking the outer zone boundary, at InpRatchetBaseLot
input double InpAsiaZoneMid   = 10.0;  // USD-equivalent distance from avg marking the mid zone boundary / limit order offset, at InpRatchetBaseLot
input ulong  InpAsiaMagic     = 100307;

input group "=== Daily Profit Stop (all magics above, incl. Asia) ==="
input double DailyProfitStopPct = 0.0;    // close all + stop trading when PnL gains this % vs snapshot balance (0 = disabled)
input double DailyProfitStopUSD = 0.0;    // close all + stop trading when PnL gains this many $ (0 = disabled). If both set, whichever is hit first wins.
input int    SnapHour            = 0;     // server-time hour (0-23) to take the daily balance snapshot. 0 = midnight.

CTrade trade;

int hEmaM30, hBbM30, hEmaM15, hBbM15, hEmaM5, hBbM5, hEmaH4, hBbH4;
datetime lastBarM30 = 0, lastBarM15 = 0, lastBarM5 = 0, lastBarH4 = 0;
datetime g_asiaLastDay = 0;
#define ASIA_LASTDAY_GVAR "EMA_BB_Cross_EA_AsiaLastDay"
datetime g_lastCrossBarM5 = 0;

//--- daily profit stop state, scoped to this EA's own positions only ---
double   g_snapshotBalance   = 0.0;
datetime g_snapshotDay       = 0;      // midnight (server time) of the snapshot day
bool     g_profitStopHit     = false;
double   g_realizedSinceSnap = 0.0;    // this EA's closed-deal PnL since the snapshot,
                                        // updated event-driven in OnTradeTransaction (no rescans)
int      g_ourOpenCount      = 0;      // this EA's own open positions, kept event-driven so
                                        // OnTick can skip the position loop entirely when flat

bool IsOurMagic(long magic)
  {
   return magic == (long)InpMagic_M30 || magic == (long)InpMagic_M15 || magic == (long)InpMagic_M5
       || magic == (long)InpMagic_H4  || magic == (long)InpAsiaMagic;
  }

int OnInit()
  {
   if(InpRatchetStepSL <= 0.0)
     {
      Print("InpRatchetStepSL must be > 0 -- 0 or negative hangs TrailStopsRatchet() in an infinite loop. EA not started.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetDeviationInPoints(InpDeviation);
   PrintFormat("SYMBOL_DEBUG tick_value=%.5f tick_size=%.5f contract_size=%.2f digits=%d point=%.5f",
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), _Point);
   hEmaM30 = iMA(_Symbol, PERIOD_M30, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hBbM30  = iBands(_Symbol, PERIOD_M30, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   hEmaM15 = iMA(_Symbol, PERIOD_M15, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hBbM15  = iBands(_Symbol, PERIOD_M15, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   hEmaM5  = iMA(_Symbol, PERIOD_M5, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hBbM5   = iBands(_Symbol, PERIOD_M5, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   hEmaH4  = iMA(_Symbol, PERIOD_H4, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hBbH4   = iBands(_Symbol, PERIOD_H4, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   if(hEmaM30==INVALID_HANDLE || hBbM30==INVALID_HANDLE || hEmaM15==INVALID_HANDLE || hBbM15==INVALID_HANDLE
      || hEmaM5==INVALID_HANDLE || hBbM5==INVALID_HANDLE || hEmaH4==INVALID_HANDLE || hBbH4==INVALID_HANDLE)
      return(INIT_FAILED);

   // baseline until the first snapshot: balance at attach
   g_snapshotBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
   g_snapshotDay       = 0;
   g_profitStopHit     = false;
   g_realizedSinceSnap = 0.0;

   // one-time scan at attach, in case the EA is (re)loaded onto an account
   // that already has open positions of ours (e.g. terminal restart)
   g_ourOpenCount = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(IsOurMagic(PositionGetInteger(POSITION_MAGIC)) && PositionGetString(POSITION_SYMBOL) == _Symbol)
         g_ourOpenCount++;
     }

   return(INIT_SUCCEEDED);
  }

// force-close any open position with this magic held longer than maxHours (0 = disabled).
// used as a time-based hard stop in place of (or alongside) a price-based SL.
void CheckHardTimeStop(ulong magic, double maxHours)
  {
   if(maxHours <= 0.0) return;
   long maxSeconds = (long)(maxHours * 3600.0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - opened >= maxSeconds)
         trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| close every open position belonging to this EA (any magic above)  |
//+------------------------------------------------------------------+
void CloseAllOurs()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(magic)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      trade.SetExpertMagicNumber((ulong)magic);
      for(int attempt = 0; attempt <= 3; attempt++)
        {
         if(trade.PositionClose(ticket)) break;
         uint code = trade.ResultRetcode();
         if(code != TRADE_RETCODE_REQUOTE && code != TRADE_RETCODE_PRICE_CHANGED)
           {
            PrintFormat("EMA_BB_Cross_EA: profit-stop close of #%I64u failed, retcode %u", ticket, code);
            break;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| cancel every still-pending order belonging to this EA (any magic  |
//| above) -- without this, a pullback/near/Asia limit could still    |
//| fill after CloseAllOurs() flattens everything else                |
//+------------------------------------------------------------------+
void CancelAllOurPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(!IsOurMagic(OrderGetInteger(ORDER_MAGIC))) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(!trade.OrderDelete(ticket))
         PrintFormat("EMA_BB_Cross_EA: profit-stop cancel of pending #%I64u failed, retcode %u", ticket, trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| floating PnL of this EA's own open positions only                 |
//+------------------------------------------------------------------+
double OurFloatingPnL()
  {
   if(g_ourOpenCount <= 0) return 0.0; // nothing of ours open, skip the scan

   double sum = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return sum;
  }

//+------------------------------------------------------------------+
//| append one line to a CSV in the shared Files folder (Common):     |
//| timestamp, label, balance, goal (%/$), earned (%/$), left to goal |
//| (%/$)                                                              |
//+------------------------------------------------------------------+
void LogProgress(string label)
  {
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double ourPnLToday = g_realizedSinceSnap + OurFloatingPnL();

   double pctThreshold = (DailyProfitStopPct > 0.0) ? g_snapshotBalance * (DailyProfitStopPct / 100.0) : DBL_MAX;
   double usdThreshold = (DailyProfitStopUSD > 0.0) ? DailyProfitStopUSD : DBL_MAX;
   double goalUsd       = MathMin(pctThreshold, usdThreshold); // effective (smaller) active goal
   double goalPct        = (g_snapshotBalance > 0.0 && goalUsd < DBL_MAX) ? goalUsd / g_snapshotBalance * 100.0 : 0.0;

   double earnedUsd = ourPnLToday;
   double earnedPct = (g_snapshotBalance > 0.0) ? earnedUsd / g_snapshotBalance * 100.0 : 0.0;

   double leftUsd = (goalUsd < DBL_MAX) ? goalUsd - earnedUsd : 0.0;
   double leftPct = (goalUsd < DBL_MAX) ? goalPct - earnedPct : 0.0;

   int h = FileOpen("EMA_BB_Cross_Balance.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), label,
             DoubleToString(balance, 2),
             (goalUsd < DBL_MAX) ? DoubleToString(goalPct, 2) + "%" : "off",
             (goalUsd < DBL_MAX) ? DoubleToString(goalUsd, 2) + "$" : "off",
             DoubleToString(earnedPct, 2) + "%", DoubleToString(earnedUsd, 2) + "$",
             (goalUsd < DBL_MAX) ? DoubleToString(leftPct, 2) + "%" : "n/a",
             (goalUsd < DBL_MAX) ? DoubleToString(leftUsd, 2) + "$" : "n/a");
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| event-driven: fires once per deal, not once per tick.              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong ticket = trans.deal;
   if(!HistoryDealSelect(ticket)) return;

   long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
   if(!IsOurMagic(magic)) return;
   if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) return;

   long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      g_ourOpenCount++;
     }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      g_ourOpenCount = MathMax(0, g_ourOpenCount - 1);
      g_realizedSinceSnap += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                           + HistoryDealGetDouble(ticket, DEAL_SWAP)
                           + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
     }
  }

//+------------------------------------------------------------------+
//| 00:00 server-time balance snapshot + profit stop scoped to THIS   |
//| EA only: snapshot balance + this EA's own floating PnL, not the   |
//| whole account. Tripping it flattens all our positions AND cancels |
//| all our pendings. Disabled entirely when both DailyProfitStopPct  |
//| and DailyProfitStopUSD = 0.                                        |
//+------------------------------------------------------------------+
void UpdateProfitStop()
  {
   if(DailyProfitStopPct <= 0.0 && DailyProfitStopUSD <= 0.0) return;

   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   datetime midnight = now - (t.hour * 3600 + t.min * 60 + t.sec);
   datetime snapPoint = midnight + SnapHour * 3600;
   if(now < snapPoint) snapPoint -= 86400;

   if(g_snapshotDay != snapPoint)
     {
      g_snapshotBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_snapshotDay       = snapPoint;
      g_profitStopHit     = false;
      g_realizedSinceSnap = 0.0;
      PrintFormat("EMA_BB_Cross_EA: %02d:00 balance snapshot %.2f", SnapHour, g_snapshotBalance);
      LogProgress(StringFormat("snapshot_%02d:00", SnapHour));
     }

   if(!g_profitStopHit && g_snapshotBalance > 0.0)
     {
      double ourPnLToday  = g_realizedSinceSnap + OurFloatingPnL();
      double pctThreshold = (DailyProfitStopPct > 0.0) ? g_snapshotBalance * (DailyProfitStopPct / 100.0) : DBL_MAX;
      double usdThreshold = (DailyProfitStopUSD > 0.0) ? DailyProfitStopUSD : DBL_MAX;
      double threshold    = MathMin(pctThreshold, usdThreshold);

      if(threshold < DBL_MAX && ourPnLToday >= threshold)
        {
         g_profitStopHit = true;
         string hitBy = (pctThreshold <= usdThreshold) ? "%" : "$";
         PrintFormat("EMA_BB_Cross_EA: this EA's PnL since snapshot +%.2f reached the %s threshold (+%.2f). "
                     "Closing all positions/pendings; no new trades until next 00:00 snapshot.",
                     ourPnLToday, hitBy, threshold);
         LogProgress("profit_stop_before_close");
         CloseAllOurs();
         CancelAllOurPendings();
         LogProgress("profit_stop_after_close");
        }
     }
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(hEmaM30);
   IndicatorRelease(hBbM30);
   IndicatorRelease(hEmaM15);
   IndicatorRelease(hBbM15);
   IndicatorRelease(hEmaM5);
   IndicatorRelease(hBbM5);
   IndicatorRelease(hEmaH4);
   IndicatorRelease(hBbH4);
  }

// tester-only: dump full deal history as CSV to Common\Files (fixed path across all agents),
// so a backtest run yields a lightweight CSV directly instead of parsing a huge .htm report.
input string InpCsvDumpName = "";  // if set, OnTester writes deals here as <name>.csv under Common\Files
double OnTester()
  {
   if(InpCsvDumpName == "") return(0.0);
   if(!HistorySelect(0, TimeCurrent())) return(0.0);
   int handle = FileOpen(InpCsvDumpName + ".csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("OnTester: FileOpen failed ret=%d", GetLastError());
      return(0.0);
     }
   FileWrite(handle, "Time","Deal","Symbol","Type","Direction","Volume","Price","Order","Commission","Swap","Profit","Balance","Comment");
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      datetime t   = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      long     type= HistoryDealGetInteger(ticket, DEAL_TYPE);
      long     entry=HistoryDealGetInteger(ticket, DEAL_ENTRY);
      string   sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      double   vol = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double   price=HistoryDealGetDouble(ticket, DEAL_PRICE);
      long     order=HistoryDealGetInteger(ticket, DEAL_ORDER);
      double   comm= HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double   swap= HistoryDealGetDouble(ticket, DEAL_SWAP);
      double   profit=HistoryDealGetDouble(ticket, DEAL_PROFIT);
      string   cmt = HistoryDealGetString(ticket, DEAL_COMMENT);
      string typeStr = (type==DEAL_TYPE_BUY) ? "buy" : (type==DEAL_TYPE_SELL) ? "sell" : (type==DEAL_TYPE_BALANCE) ? "balance" : "other";
      string dirStr  = (entry==DEAL_ENTRY_IN) ? "in" : (entry==DEAL_ENTRY_OUT) ? "out" : (entry==DEAL_ENTRY_INOUT) ? "inout" : "";
      FileWrite(handle, TimeToString(t, TIME_DATE|TIME_SECONDS), (long)ticket, sym, typeStr, dirStr, vol, price, order, comm, swap, profit, "", cmt);
     }
   FileClose(handle);
   PrintFormat("OnTester: wrote %d deals to Common\\Files\\%s.csv", total, InpCsvDumpName);
   return(0.0);
  }

// windows = "1-3,15-20" (comma-separated "startHour-endHour", 0-23, end exclusive), SERVER
// time. "" = always allowed. A window that wraps midnight (start > end, e.g. "22-2") is
// supported: matches hour >= start OR hour < end.
bool TradingHourAllowed(string windows)
  {
   if(windows == "") return true;
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   int hour = tm.hour;

   string ranges[];
   int n = StringSplit(windows, ',', ranges);
   for(int i = 0; i < n; i++)
     {
      string part = ranges[i];
      int dash = StringFind(part, "-");
      if(dash < 0) continue;
      int start = (int)StringToInteger(StringSubstr(part, 0, dash));
      int end   = (int)StringToInteger(StringSubstr(part, dash+1));
      if(start <= end) { if(hour >= start && hour < end) return true; }
      else              { if(hour >= start || hour < end) return true; }
     }
   return false;
  }

// true if EMA crossed the BB middle line on the last CLOSED bar (index 1 vs 2)
// dir: +1 = crossed up (buy), -1 = crossed down (sell), 0 = no cross
// predicts an imminent cross BEFORE it confirms: same-side gap that has shrunk toward zero over
// the last 2 closed bars. Returns 1 (buy imminent, ema below mid and closing in), -1 (sell imminent),
// or 0 (no prediction). gapMaxPrice is the raw |ema-mid| price-unit ceiling to consider "close enough".
int CheckPreCross(int hEma, int hBb, double gapMaxPrice, bool requireShrinking)
  {
   double ema[2], mid[2];
   if(CopyBuffer(hEma, 0, 1, 2, ema) != 2) return(0);
   if(CopyBuffer(hBb, 0, 1, 2, mid) != 2) return(0);
   double diff2 = ema[0] - mid[0]; // shift2 (older)
   double diff1 = ema[1] - mid[1]; // shift1 (last closed, newer)
   if(diff1 == 0.0) return(0);
   if(diff1 * diff2 <= 0.0) return(0); // already crossed (or exactly on it) -- not a pre-cross
   if(MathAbs(diff1) > gapMaxPrice) return(0);
   if(requireShrinking && MathAbs(diff1) >= MathAbs(diff2)) return(0);
   return (diff1 < 0.0) ? 1 : -1; // ema below mid and closing in => upward cross imminent => buy
  }

int CheckCross(int hEma, int hBb)
  {
   double ema[3], mid[3];
   if(CopyBuffer(hEma, 0, 1, 2, ema) != 2) return(0);
   if(CopyBuffer(hBb, 0, 1, 2, mid) != 2) return(0);
   bool wasBelow = ema[0] < mid[0];
   bool nowAbove = ema[1] > mid[1];
   bool wasAbove = ema[0] > mid[0];
   bool nowBelow = ema[1] < mid[1];
   if(wasBelow && nowAbove) return(1);
   if(wasAbove && nowBelow) return(-1);
   return(0);
  }

int CountOpen(ulong magic)
  {
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)magic)
         count++;
     }
   return(count);
  }

// counts still-pending (unfilled) orders for a magic -- CountOpen() alone misses these,
// so a maxOrders cap checked with CountOpen() only could let pending limits stack past it.
int CountPending(ulong magic)
  {
   int count = 0;
   for(int i=0; i<OrdersTotal(); i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && OrderGetInteger(ORDER_MAGIC)==(long)magic)
         count++;
     }
   return(count);
  }

// converts a USD target into a price distance using the symbol's real tick value,
// so SL/TP land on the correct price regardless of contract size/quote currency.
double UsdToPriceDistance(double usdTarget, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return(0.0);
   return(usdTarget / lots / tickValue * tickSize);
  }

// inverse of UsdToPriceDistance: converts a price distance back into its USD value
double PriceDistanceToUsd(double priceDist, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) return(0.0);
   return(priceDist * lots * tickValue / tickSize);
  }

// every USD input (TP/SL, trail trigger/lock, ratchet thresholds) is written as if
// trading InpRatchetBaseLot (0.01). This returns how many multiples of that base the
// given lot is (x1, x2, x3...), so ALL of them can be scaled together with one factor --
// keeping every ratio (e.g. trigger vs TP) identical no matter what lot is actually used.
double LotScale(double lots)
  {
   return (InpRatchetBaseLot > 0.0) ? lots / InpRatchetBaseLot : 1.0;
  }

// swingHigh - (swingHigh-swingLow)*ratio, swing = highest-high/lowest-low over the last
// lookback CLOSED bars (bar 0, the forming bar, excluded) of the given timeframe. Starting
// at startRatio, steps to the next deeper standard ratio until a level clears floorPrice
// (at or below it) -- but if a level misses the floor by no more than tolerance, snap to
// floorPrice instead of stepping deeper. Returns 0.0 if no swing data, or nothing (even the
// deepest ratio) gets within tolerance of the floor.
double FibSupportLevel(ENUM_TIMEFRAMES period, int lookback, double startRatio, double floorPrice, double tolerance)
  {
   int hiIdx = iHighest(_Symbol, period, MODE_HIGH, lookback, 1);
   int loIdx = iLowest(_Symbol, period, MODE_LOW, lookback, 1);
   if(hiIdx < 0 || loIdx < 0) return(0.0);
   double hi = iHigh(_Symbol, period, hiIdx);
   double lo = iLow(_Symbol, period, loIdx);

   static double ratios[6] = {0.236, 0.382, 0.5, 0.618, 0.786, 1.0};
   for(int i = 0; i < 6; i++)
     {
      if(ratios[i] < startRatio - 0.0001) continue; // skip ratios shallower than the configured start
      double level = hi - (hi - lo) * ratios[i];
      if(level <= floorPrice) return(level); // deep enough
      if(level - floorPrice <= tolerance) return(floorPrice); // close enough -- snap to the floor
     }
   return(0.0); // even the deepest ratio in this swing misses the floor by more than tolerance
  }

// M15/M30/H4 (buy-only): up-cross chases price with a near buy-limit, gated on distance
// already run from the cross point (else buy-limit sits right at current price); down-cross
// buys the dip at a real fib-retracement support level (see FibSupportLevel above).
void TryTradeNear(int hEma, int hBb, ulong magic, double lots, double tpUsd, double slUsd, int maxOrders, string tfLabel,
                   double gateUsd, double nearUsd, ENUM_TIMEFRAMES period, int fibLookback, double fibRatio, double fibMinDistUsd,
                   bool blockUp, bool blockDown)
  {
   int dir = CheckCross(hEma, hBb);
   if(dir == 0) return;
   if(dir == 1 && blockUp) return;
   if(dir == -1 && blockDown) return;
   if(maxOrders > 0 && (CountOpen(magic) + CountPending(magic)) >= maxOrders) return;

   double mid[1];
   if(CopyBuffer(hBb, 0, 1, 1, mid) != 1) return; // BB mid at the cross bar = cross point x
   double x = mid[0];

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double a = tick.bid;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double scale = LotScale(lots);
   double limitPrice;
   if(dir == 1) // up-cross: chase with a pullback if price ran far enough past the cross point, else buy limit right at current price
     {
      double gateDist = UsdToPriceDistance(gateUsd * scale, lots);
      if(gateDist <= 0.0) return;
      double offsetUsd = ((a - x) > gateDist) ? nearUsd : 0.0;
      double offsetDist = (offsetUsd > 0.0) ? UsdToPriceDistance(offsetUsd * scale, lots) : 0.0;
      limitPrice = NormalizeDouble(a - offsetDist, digits);
     }
   else // down-cross: buy the dip at the fib support level, at least fibMinDistUsd below price
     {
      double floorPrice = a - UsdToPriceDistance(fibMinDistUsd * scale, lots);
      double tolerance  = UsdToPriceDistance(InpFibFloorTolerance * scale, lots);
      double level = FibSupportLevel(period, fibLookback, fibRatio, floorPrice, tolerance);
      if(level <= 0.0 || level >= a) return; // no swing data, or nothing deep enough clears the floor
      limitPrice = NormalizeDouble(level, digits);
     }

   double slDist = (slUsd > 0.0) ? UsdToPriceDistance(slUsd * scale, lots) : 0.0;
   double tpDist = UsdToPriceDistance(tpUsd * scale, lots);
   if(tpDist <= 0.0) return;

   EnsurePendingDistance(true, limitPrice, digits);

   double sl = (slDist > 0.0) ? NormalizeDouble(limitPrice - slDist, digits) : 0.0;
   double tp = NormalizeDouble(limitPrice + tpDist, digits);
   ClampToStopsLevelFromPrice(limitPrice, true, sl, tp, digits);

   trade.SetExpertMagicNumber(magic);
   if(!trade.BuyLimit(lots, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tfLabel + "_crossbuy"))
      PrintFormat("%s cross buy-limit failed ret=%d %s", tfLabel, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

// M1/M5 only: on cross, enter INSTANT at market in the cross's direction (no pending/pullback).
void TryTradeMarket(int hEma, int hBb, ulong magic, double lots, double tpPriceDist, double slPriceDist, int maxOrders, string tfLabel,
                     ENUM_TIMEFRAMES period, int cooldownBars, datetime &lastCrossBar,
                     bool blockUp, bool blockDown,
                     bool useTrendFilter=false, int hTrendMa=INVALID_HANDLE,
                     bool useVolFilter=false, double minBbWidthUsd=0.0,
                     int blockPhaseMask=0,
                     int minuteFilterBuy=-1, int minuteFilterSell=-1,
                     bool reverseSignal=false,
                     bool usePreCross=false, double preCrossGapMax=0.0, bool preCrossRequireShrink=true)
  {
   int dir = usePreCross ? CheckPreCross(hEma, hBb, preCrossGapMax, preCrossRequireShrink) : CheckCross(hEma, hBb);
   if(dir == 0) return;
   if(reverseSignal) dir = -dir;
   if(dir == 1 && blockUp) return;
   if(dir == -1 && blockDown) return;

   if(dir == 1 && minuteFilterBuy >= 0)
     {
      MqlDateTime dtm; TimeToStruct(iTime(_Symbol, period, 0), dtm);
      if(dtm.min != minuteFilterBuy) return;
     }
   if(dir == -1 && minuteFilterSell >= 0)
     {
      MqlDateTime dtm; TimeToStruct(iTime(_Symbol, period, 0), dtm);
      if(dtm.min != minuteFilterSell) return;
     }

   // diagnostic only: |EMA-BBmid| gap in USD @ this trade's lot, at the cross bar -- embedded
   // in the order comment so it can be correlated with win/loss from the tester report later,
   // without needing to re-derive indicator values from raw price history after the fact.
   double gapUsdTag = 0.0;
   {
      double emaBuf[1], midBuf[1];
      if(CopyBuffer(hEma, 0, 1, 1, emaBuf) == 1 && CopyBuffer(hBb, 0, 1, 1, midBuf) == 1)
         gapUsdTag = PriceDistanceToUsd(MathAbs(emaBuf[0] - midBuf[0]), lots);
   }

   if(blockPhaseMask != 0)
     {
      MqlDateTime dt;
      TimeToStruct(iTime(_Symbol, period, 0), dt);
      int phase = dt.min % 5;
      if((blockPhaseMask & (1 << phase)) != 0) return;
     }

   if(useTrendFilter && hTrendMa != INVALID_HANDLE)
     {
      double maBuf[1];
      if(CopyBuffer(hTrendMa, 0, 1, 1, maBuf) == 1)
        {
         double price = iClose(_Symbol, period, 1);
         if(dir == 1 && price < maBuf[0]) return;  // only buy above trend MA
         if(dir == -1 && price > maBuf[0]) return; // only sell below trend MA
        }
     }

   if(useVolFilter && minBbWidthUsd > 0.0)
     {
      double upper[1], lower[1];
      if(CopyBuffer(hBb, 1, 1, 1, upper) == 1 && CopyBuffer(hBb, 2, 1, 1, lower) == 1)
        {
         double widthUsd = PriceDistanceToUsd(upper[0] - lower[0], lots);
         if(widthUsd < minBbWidthUsd) return;
        }
     }

   datetime thisCrossBar = iTime(_Symbol, period, 0);
   if(cooldownBars > 0 && lastCrossBar != 0)
     {
      int barsSince = iBarShift(_Symbol, period, lastCrossBar, false);
      if(barsSince >= 0 && barsSince < cooldownBars) return;
     }

   if(maxOrders > 0 && (CountOpen(magic) + CountPending(magic)) >= maxOrders) return;

   // slPriceDist/tpPriceDist are raw price-distance (e.g. 5.0, 9.0 on XAUUSD), NOT USD-per-lot --
   // unlike the other timeframes' TryTradeNear(), this skips UsdToPriceDistance()/tick-value
   // conversion entirely so the input means the same distance on any symbol/broker.
   double slDist = (slPriceDist > 0.0) ? slPriceDist : 0.0;
   double tpDist = tpPriceDist;
   if(tpDist <= 0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   trade.SetExpertMagicNumber(magic);

   bool isBuy = (dir == 1);
   double refPrice = isBuy ? tick.ask : tick.bid;
   // diagnostic: signed distance from the actual entry price to the INTERPOLATED cross point --
   // the price level where EMA and BB-mid geometrically intersect between bar2 (still on the old
   // side) and bar1 (confirmed on the new side), not just bar1's close. Linear-interpolate along
   // (ema-mid) between the two bars to find where that difference crosses zero, then map that
   // fraction onto the BB-mid's own price path to get the intersection price level.
   double slipUsdTag = 0.0;
   {
      double ema2[1], mid2[1], ema1[1], mid1[1];
      if(CopyBuffer(hEma, 0, 2, 1, ema2) == 1 && CopyBuffer(hBb, 0, 2, 1, mid2) == 1 &&
         CopyBuffer(hEma, 0, 1, 1, ema1) == 1 && CopyBuffer(hBb, 0, 1, 1, mid1) == 1)
        {
         double diff2 = ema2[0] - mid2[0];
         double diff1 = ema1[0] - mid1[0];
         double denom = diff2 - diff1;
         if(MathAbs(denom) > 0.0)
           {
            double t = diff2 / denom; // fraction from bar2 to bar1 where (ema-mid) hits zero
            double crossPrice = mid2[0] + t * (mid1[0] - mid2[0]);
            double signedDist = refPrice - crossPrice;
            slipUsdTag = ((signedDist >= 0) ? 1.0 : -1.0) * PriceDistanceToUsd(MathAbs(signedDist), lots);
           }
        }
   }

   double sl = 0.0, tp = 0.0;
   if(isBuy)
     {
      sl = (slDist > 0.0) ? NormalizeDouble(refPrice - slDist, digits) : 0.0;
      tp = NormalizeDouble(refPrice + tpDist, digits);
     }
   else
     {
      sl = (slDist > 0.0) ? NormalizeDouble(refPrice + slDist, digits) : 0.0;
      tp = NormalizeDouble(refPrice - tpDist, digits);
     }
   ClampToStopsLevel(isBuy, sl, tp, digits);

   // diagnostic: distance from entry to the nearest swing high/low (real wicks) over the last
   // InpSwingLookback_M5 CLOSED bars, on the stop-loss side of the trade -- small distance means
   // entry sits right at a recent support/resistance level, large means it's out in open space.
   double swingDistTag = 0.0;
   {
      int hh = iHighest(_Symbol, period, MODE_HIGH, InpSwingLookback_M5, 1);
      int ll = iLowest(_Symbol, period, MODE_LOW, InpSwingLookback_M5, 1);
      if(hh >= 0 && ll >= 0)
        {
         double swingHigh = iHigh(_Symbol, period, hh);
         double swingLow  = iLow(_Symbol, period, ll);
         swingDistTag = isBuy ? (refPrice - swingLow) : (swingHigh - refPrice);
        }
   }

   string gapTag = StringFormat("_g%.2f_s%.2f_w%.2f", gapUsdTag, slipUsdTag, swingDistTag);
   bool sent = isBuy
      ? trade.Buy(lots, _Symbol, refPrice, sl, tp, tfLabel + "_crossbuy" + gapTag)
      : trade.Sell(lots, _Symbol, refPrice, sl, tp, tfLabel + "_crosssell" + gapTag);
   if(sent)
     {
      RealignAsiaSL(isBuy, slDist, digits); // re-anchor SL to actual fill price (slippage), TP left on absolute target
      if(cooldownBars > 0)
         lastCrossBar = thisCrossBar;
     }
   else
      PrintFormat("%s market entry failed ret=%d %s", tfLabel, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

// clamps sl/tp candidates so they respect the broker's min stop/freeze distance from a
// reference price; without this, brokers reject the WHOLE request (both fields) whenever
// either one lands too close. For an open position or a market order, refPrice is the
// current market price. For a PENDING order (BuyLimit/SellLimit), MT5 measures the SL/TP
// distance from the order's OWN price, not current market price -- so refPrice must be
// that order's price, not tick.bid/ask.
void ClampToStopsLevelFromPrice(double refPrice, bool isBuy, double &sl, double &tp, int digits)
  {
   long stopLevelPts   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax(stopLevelPts, freezeLevelPts) * _Point + _Point;
   if(minDist <= _Point) return;

   if(sl > 0.0)
     {
      if(isBuy && (refPrice - sl) < minDist) sl = NormalizeDouble(refPrice - minDist, digits);
      if(!isBuy && (sl - refPrice) < minDist) sl = NormalizeDouble(refPrice + minDist, digits);
     }
   if(tp > 0.0)
     {
      if(isBuy && (tp - refPrice) < minDist) tp = NormalizeDouble(refPrice + minDist, digits);
      if(!isBuy && (refPrice - tp) < minDist) tp = NormalizeDouble(refPrice - minDist, digits);
     }
  }

// convenience wrapper for open positions / market orders: reference price is current market price
void ClampToStopsLevel(bool isBuy, double &sl, double &tp, int digits)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double curPrice = isBuy ? tick.bid : tick.ask;
   ClampToStopsLevelFromPrice(curPrice, isBuy, sl, tp, digits);
  }

// re-anchor SL to the ACTUAL fill price after an Asia "now" market order -- Slippage lets
// the real fill land away from the pre-send tick.bid/ask that slDist was measured from. TP
// is left untouched: it targets the absolute avg price, which doesn't drift with slippage.
void RealignAsiaSL(bool isBuy, double slDist, int digits)
  {
   ulong dealTicket = trade.ResultDeal();
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;

   ulong posTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(!PositionSelectByTicket(posTicket)) return;

   double actualEntry = PositionGetDouble(POSITION_PRICE_OPEN);
   double correctSL = NormalizeDouble(isBuy ? actualEntry - slDist : actualEntry + slDist, digits);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   if(MathAbs(curSL - correctSL) < _Point) return; // already right

   ClampToStopsLevel(isBuy, correctSL, curTP, digits);
   if(!trade.PositionModify(posTicket, correctSL, curTP))
      PrintFormat("EMA_BB_Cross_EA: Asia SL realign on #%I64u failed, retcode %d", posTicket, trade.ResultRetcode());
  }

// separate MT5 rule from the SL/TP clamp above: a PENDING order's own price must also sit
// at least the stops/freeze distance away from the CURRENT market price, or the broker
// rejects placement outright. Pushes orderPrice further away if it's too close.
void EnsurePendingDistance(bool isBuy, double &orderPrice, int digits)
  {
   long stopLevelPts   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax(stopLevelPts, freezeLevelPts) * _Point + _Point;
   if(minDist <= _Point) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double refPrice = isBuy ? tick.bid : tick.ask;

   if(isBuy && (refPrice - orderPrice) < minDist) orderPrice = NormalizeDouble(refPrice - minDist, digits);
   if(!isBuy && (orderPrice - refPrice) < minDist) orderPrice = NormalizeDouble(refPrice + minDist, digits);
  }

// throttles retries of a REJECTED PositionModify() per ticket -- relying on exact sl/tp
// value equality (the previous approach) failed to suppress repeats when the ratchet's
// computed target drifted by tiny float amounts between ticks, so this instead just skips
// a ticket that failed within the last N seconds regardless of the new target's exact value.
// Without this, a target that stays invalid for many ticks in a row (e.g. computed just ahead
// of where price has actually reached) retries forever, one PositionModify()+Print() per tick,
// for as long as the position stays open -- this is what made full-history M1/M5 backtests
// take hours instead of seconds.
ulong g_failModifyTicket[64];
datetime g_failModifyUntil[64];
int   g_failModifyCount = 0;
const int FAIL_MODIFY_RETRY_SEC = 5;

void DoModify(ulong ticket, double newSL, double newTP)
  {
   datetime now = TimeCurrent();
   for(int i=0; i<g_failModifyCount; i++)
     {
      if(g_failModifyTicket[i] != ticket) continue;
      if(now < g_failModifyUntil[i]) return; // still in cooldown from a recent rejection
      break;
     }

   if(trade.PositionModify(ticket, newSL, newTP))
     {
      for(int i=0; i<g_failModifyCount; i++)
         if(g_failModifyTicket[i] == ticket)
           {
            g_failModifyTicket[i] = g_failModifyTicket[g_failModifyCount-1];
            g_failModifyUntil[i]  = g_failModifyUntil[g_failModifyCount-1];
            g_failModifyCount--;
            break;
           }
      return;
     }

   MqlTick dbgTick; SymbolInfoTick(_Symbol, dbgTick);
   PrintFormat("Modify failed #%I64u bid=%.5f ask=%.5f ret=%d %s sl=%.5f tp=%.5f", ticket, dbgTick.bid, dbgTick.ask, trade.ResultRetcode(),
               trade.ResultRetcodeDescription(), newSL, newTP);
   for(int i=0; i<g_failModifyCount; i++)
      if(g_failModifyTicket[i] == ticket) { g_failModifyUntil[i]=now+FAIL_MODIFY_RETRY_SEC; return; }
   if(g_failModifyCount < 64)
     {
      g_failModifyTicket[g_failModifyCount] = ticket;
      g_failModifyUntil[g_failModifyCount]  = now+FAIL_MODIFY_RETRY_SEC;
      g_failModifyCount++;
     }
  }

// once floating profit hits InpTrailTrigger, lock InpTrailLock and slide SL up 1:1 with
// further profit; TP starts from its ORIGINAL price and slides at InpTrailTpRatio per $1
// of SL movement (< 1.0 so price can eventually catch up and TP stays reachable).
void TrailStops(ulong magic, double tpUsd, double trailTrigger, double trailLock)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=(long)magic) continue;

      double lots  = PositionGetDouble(POSITION_VOLUME);
      double scale = LotScale(lots);
      double scaledTrigger = trailTrigger * scale;
      double scaledLock    = trailLock * scale;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit < scaledTrigger) continue;

      double lockUsd = scaledLock + (profit - scaledTrigger);
      double tpTargetUsd = tpUsd * scale + InpTrailTpRatio * (profit - scaledTrigger);
      double lockDist = UsdToPriceDistance(lockUsd, lots);
      double tpDist   = UsdToPriceDistance(tpTargetUsd, lots);
      if(lockDist <= 0.0 || tpDist <= 0.0) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;

      double slCandidate = isBuy ? NormalizeDouble(entry + lockDist, digits)
                                  : NormalizeDouble(entry - lockDist, digits);
      double tpCandidate = isBuy ? NormalizeDouble(entry + tpDist, digits)
                                  : NormalizeDouble(entry - tpDist, digits);

      // only ever move favorably: SL up (buy) / down (sell), TP further out in the same direction
      double newSL = isBuy ? MathMax(slCandidate, curSL) : MathMin(slCandidate, curSL);
      double newTP = isBuy ? MathMax(tpCandidate, curTP) : MathMin(tpCandidate, curTP);
      ClampToStopsLevel(isBuy, newSL, newTP, digits);
      if(newSL != curSL || newTP != curTP)
         DoModify(ticket, newSL, newTP);
     }
  }

// Ratchet trail (M1/M5, tuned at 0.01 lot via InpRatchetBaseLot -- values scale with lot).
// Collapsed to flat per-stage values (instead of a continuous profit-based formula) so
// PositionModify() only fires on real stage transitions, not on every tick's tiny profit tick.
// below $1.5 profit: SL/TP stay at their initial open values.
// Stage 1 ($1.5-$3.0 profit): SL untouched (original open-time stop), TP flat at $5.0.
// Stage 2 (profit >= $3.0): SL/TP reset straight to $2.0/$6.1, then whenever profit runs $3
// ahead of the current locked SL, ratchet SL up $1 and TP up $0.9 (repeats as profit keeps
// climbing). The favorable-only clamp below still stops this reset from ever moving SL/TP
// backward in absolute terms.
void TrailStopsRatchet(ulong magic)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=(long)magic) continue;

      double lots  = PositionGetDouble(POSITION_VOLUME);
      double scale = LotScale(lots);

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit < InpRatchetArm * scale) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;

      double curSLUsd = isBuy ? PriceDistanceToUsd(curSL - entry, lots) : PriceDistanceToUsd(entry - curSL, lots);
      double curTPUsd = isBuy ? PriceDistanceToUsd(curTP - entry, lots) : PriceDistanceToUsd(entry - curTP, lots);

      double slUsd, tpUsd;
      if(profit < InpRatchetS1End * scale)
        {
         slUsd = curSLUsd; // don't touch SL yet -- locking it flush with profit at the arm
                            // point leaves zero cushion, i.e. one tick back closes the trade
                            // immediately. Only TP trails in Stage 1; SL waits for Stage 2.
         tpUsd = InpRatchetS1TP * scale;
        }
      else
        {
         slUsd = InpRatchetS2SL * scale;
         tpUsd = InpRatchetS2TP * scale;
         while(profit - slUsd >= InpRatchetStep * scale)
           {
            slUsd += InpRatchetStepSL * scale;
            tpUsd += InpRatchetStepTP * scale;
           }
        }

      // only ever move favorably
      slUsd = MathMax(slUsd, curSLUsd);
      tpUsd = MathMax(tpUsd, curTPUsd);

      double slDist = UsdToPriceDistance(slUsd, lots);
      double tpDist = UsdToPriceDistance(tpUsd, lots);
      // slDist is legitimately negative in Stage 1 (SL still below entry, unmoved on purpose) --
      // only tpDist <= 0.0 signals a real failure (invalid tick data), so only that gates the update.
      if(tpDist <= 0.0) continue;

      double newSL = isBuy ? NormalizeDouble(entry + slDist, digits) : NormalizeDouble(entry - slDist, digits);
      double newTP = isBuy ? NormalizeDouble(entry + tpDist, digits) : NormalizeDouble(entry - tpDist, digits);
      ClampToStopsLevel(isBuy, newSL, newTP, digits);

      if(newSL != curSL || newTP != curTP)
         DoModify(ticket, newSL, newTP);
     }
  }

// cancels a pending BuyLimit/SellLimit for magic/period if it's sat unfilled for
// maxBars closed candles of that timeframe since ORDER_TIME_SETUP. maxBars<=0 disables.
void CancelStalePending(ulong magic, ENUM_TIMEFRAMES period, int maxBars)
  {
   if(maxBars <= 0) return;
   for(int i = OrdersTotal()-1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)magic) continue;

      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      int barsElapsed = iBarShift(_Symbol, period, setupTime, false);
      if(barsElapsed < maxBars) continue;

      if(!trade.OrderDelete(ticket))
         PrintFormat("Stale pending cancel failed #%I64u ret=%d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

// deletes any still-pending (unfilled) BuyLimit/SellLimit from a previous day before the
// new day's orders go in -- otherwise stale limit orders stack up day after day.
void CancelAsiaPending()
  {
   for(int i = OrdersTotal()-1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)InpAsiaMagic) continue;
      if(!trade.OrderDelete(ticket))
         PrintFormat("Asia pending cancel failed #%I64u ret=%d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

// Once per day, right after InpAsiaEndHour:00 server time, freeze avg = (session High+Low)/2
// from today's 00:00 to that hour, then place the day's orders around it and never touch
// them again. Fully standalone: own magic, own lot, own SL/TP, doesn't read/affect the
// EMA/BB signals or trails above.
void AsiaSessionRange()
  {
   if(!InpAsiaEnabled) return;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   if(tm.hour < InpAsiaEndHour) return;

   datetime todayStart = TimeCurrent() - (tm.hour*3600 + tm.min*60 + tm.sec);
   if(g_asiaLastDay == 0 && GlobalVariableCheck(ASIA_LASTDAY_GVAR))
      g_asiaLastDay = (datetime)GlobalVariableGet(ASIA_LASTDAY_GVAR);
   if(g_asiaLastDay == todayStart) return; // already placed today (survives EA restart via global var)
   g_asiaLastDay = todayStart;
   GlobalVariableSet(ASIA_LASTDAY_GVAR, (double)todayStart);
   CancelAsiaPending();

   datetime cutoff = todayStart + InpAsiaEndHour*3600;
   int barTo   = iBarShift(_Symbol, PERIOD_H1, todayStart, false);
   int barFrom = iBarShift(_Symbol, PERIOD_H1, cutoff, false);
   if(barTo < 0 || barFrom < 0) return;
   int count = barTo - barFrom + 1;
   if(count <= 0) return;

   int hiIdx = iHighest(_Symbol, PERIOD_H1, MODE_HIGH, count, barFrom);
   int loIdx = iLowest(_Symbol, PERIOD_H1, MODE_LOW, count, barFrom);
   if(hiIdx < 0 || loIdx < 0) return;
   double sessHigh = iHigh(_Symbol, PERIOD_H1, hiIdx);
   double sessLow  = iLow(_Symbol, PERIOD_H1, loIdx);
   double avg = (sessHigh + sessLow) / 2.0;

   double scale   = LotScale(InpAsiaLots);
   int digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double slDist  = UsdToPriceDistance(InpAsiaSL * scale, InpAsiaLots);
   double tpDist  = UsdToPriceDistance(InpAsiaTP * scale, InpAsiaLots);
   double outer   = UsdToPriceDistance(InpAsiaZoneOuter * scale, InpAsiaLots);
   double mid     = UsdToPriceDistance(InpAsiaZoneMid * scale, InpAsiaLots);
   if(slDist <= 0.0 || tpDist <= 0.0 || outer <= 0.0 || mid <= 0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   trade.SetExpertMagicNumber(InpAsiaMagic);
   double avgN     = NormalizeDouble(avg, digits);
   double avgPlusM = NormalizeDouble(avg + mid, digits);
   double avgMinusM= NormalizeDouble(avg - mid, digits);
   double d = tick.bid - avg;

   if(d > outer)
     {
      // extreme above avg: buy the reversion at avg, real TP target
      double orderPrice = avgN;
      EnsurePendingDistance(true, orderPrice, digits);
      double sl = NormalizeDouble(orderPrice - slDist, digits);
      double tp = NormalizeDouble(orderPrice + tpDist, digits);
      ClampToStopsLevelFromPrice(orderPrice, true, sl, tp, digits);
      trade.BuyLimit(InpAsiaLots, orderPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "Asia range buy@avg");
     }
   else if(d > mid)
     {
      // mid zone above avg: sell now back toward avg, plus a buy limit below avg
      double sl1 = NormalizeDouble(tick.bid + slDist, digits);
      double tp1 = avgN;
      ClampToStopsLevel(false, sl1, tp1, digits);
      trade.Sell(InpAsiaLots, _Symbol, tick.bid, sl1, tp1, "Asia range sell now");
      RealignAsiaSL(false, slDist, digits);
      double orderPrice2 = avgMinusM;
      EnsurePendingDistance(true, orderPrice2, digits);
      double sl2 = NormalizeDouble(orderPrice2 - slDist, digits);
      double tp2 = avgN;
      ClampToStopsLevelFromPrice(orderPrice2, true, sl2, tp2, digits);
      trade.BuyLimit(InpAsiaLots, orderPrice2, _Symbol, sl2, tp2, ORDER_TIME_GTC, 0, "Asia range buy@avg-mid");
     }
   else if(d < -outer)
     {
      // extreme below avg: sell the reversion at avg, real TP target
      double orderPrice = avgN;
      EnsurePendingDistance(false, orderPrice, digits);
      double sl = NormalizeDouble(orderPrice + slDist, digits);
      double tp = NormalizeDouble(orderPrice - tpDist, digits);
      ClampToStopsLevelFromPrice(orderPrice, false, sl, tp, digits);
      trade.SellLimit(InpAsiaLots, orderPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "Asia range sell@avg");
     }
   else if(d < -mid)
     {
      // mid zone below avg: buy now back toward avg, plus a sell limit above avg
      double sl1 = NormalizeDouble(tick.ask - slDist, digits);
      double tp1 = avgN;
      ClampToStopsLevel(true, sl1, tp1, digits);
      trade.Buy(InpAsiaLots, _Symbol, tick.ask, sl1, tp1, "Asia range buy now");
      RealignAsiaSL(true, slDist, digits);
      double orderPrice2 = avgPlusM;
      EnsurePendingDistance(false, orderPrice2, digits);
      double sl2 = NormalizeDouble(orderPrice2 + slDist, digits);
      double tp2 = avgN;
      ClampToStopsLevelFromPrice(orderPrice2, false, sl2, tp2, digits);
      trade.SellLimit(InpAsiaLots, orderPrice2, _Symbol, sl2, tp2, ORDER_TIME_GTC, 0, "Asia range sell@avg+mid");
     }
   else
     {
      // inner zone: fade both sides back toward avg
      double orderPriceSell = avgPlusM;
      EnsurePendingDistance(false, orderPriceSell, digits);
      double sl1 = NormalizeDouble(orderPriceSell + slDist, digits);
      double tp1 = avgN;
      ClampToStopsLevelFromPrice(orderPriceSell, false, sl1, tp1, digits);
      trade.SellLimit(InpAsiaLots, orderPriceSell, _Symbol, sl1, tp1, ORDER_TIME_GTC, 0, "Asia range sell@avg+mid");
      double orderPriceBuy = avgMinusM;
      EnsurePendingDistance(true, orderPriceBuy, digits);
      double sl2 = NormalizeDouble(orderPriceBuy - slDist, digits);
      double tp2 = avgN;
      ClampToStopsLevelFromPrice(orderPriceBuy, true, sl2, tp2, digits);
      trade.BuyLimit(InpAsiaLots, orderPriceBuy, _Symbol, sl2, tp2, ORDER_TIME_GTC, 0, "Asia range buy@avg-mid");
     }
  }

void OnTick()
  {
   UpdateProfitStop();

   if(!g_profitStopHit)
      AsiaSessionRange();

   datetime barM30 = iTime(_Symbol, PERIOD_M30, 0);
   datetime barM15 = iTime(_Symbol, PERIOD_M15, 0);
   datetime barM5  = iTime(_Symbol, PERIOD_M5, 0);
   datetime barH4  = iTime(_Symbol, PERIOD_H4, 0);

   if(barM30 != lastBarM30)
     {
      lastBarM30 = barM30;
      if(!g_profitStopHit && InpEnabled_M30 && TradingHourAllowed(InpTradeHours_M30))
         TryTradeNear(hEmaM30, hBbM30, InpMagic_M30, InpLots_M30, InpTP_M30, InpSL_M30, InpMaxOrders, "M30",
                      InpCrossGateUp, InpNearOffset_M15M30, PERIOD_M30, InpFibLookback, InpFibRatio_M15M30, InpFibMinDist_M15M30,
                      InpBlockCrossUp_M30, InpBlockCrossDown_M30);
     }
   if(barM15 != lastBarM15)
     {
      lastBarM15 = barM15;
      if(!g_profitStopHit && InpEnabled_M15 && TradingHourAllowed(InpTradeHours_M15))
         TryTradeNear(hEmaM15, hBbM15, InpMagic_M15, InpLots_M15, InpTP_M15, InpSL_M15, InpMaxOrders, "M15",
                      InpCrossGateUp, InpNearOffset_M15M30, PERIOD_M15, InpFibLookback, InpFibRatio_M15M30, InpFibMinDist_M15M30,
                      InpBlockCrossUp_M15, InpBlockCrossDown_M15);
     }
   if(barM5 != lastBarM5)
     {
      lastBarM5 = barM5;
      CheckHardTimeStop(InpMagic_M5, InpHardTimeStopHours_M5);
      if(!g_profitStopHit && InpEnabled_M5 && TradingHourAllowed(InpTradeHours_M5))
         TryTradeMarket(hEmaM5, hBbM5, InpMagic_M5, InpLots_M5, InpTP_M5, InpSL_M5, InpMaxOrders_M5, "M5",
                       PERIOD_M5, InpCooldownBars_M5, g_lastCrossBarM5, InpBlockCrossUp_M5, InpBlockCrossDown_M5,
                       InpUseTrendFilter_M5, hEmaH4, false, 0.0, 0,
                       InpMinuteFilterBuy_M5, InpMinuteFilterSell_M5,
                       InpReverseSignal_M5,
                       InpUsePreCross_M5, InpPreCrossGapMax_M5, InpPreCrossRequireShrink_M5);
     }
   if(barH4 != lastBarH4)
     {
      lastBarH4 = barH4;
      if(!g_profitStopHit && InpEnabled_H4 && TradingHourAllowed(InpTradeHours_H4))
         TryTradeNear(hEmaH4, hBbH4, InpMagic_H4, InpLots_H4, InpTP_H4, InpSL_H4, InpMaxOrders_H4, "H4",
                      InpCrossGateUp, InpNearOffset_H4, PERIOD_H4, InpFibLookback, InpFibRatio_H4, InpFibMinDist_H4,
                      InpBlockCrossUp_H4, InpBlockCrossDown_H4);
     }
   TrailStops(InpMagic_M30, InpTP_M30, InpTrailTrigger, InpTrailLock);
   TrailStops(InpMagic_M15, InpTP_M15, InpTrailTrigger, InpTrailLock);
   TrailStops(InpMagic_H4, InpTP_H4, InpTrailTrigger_H4, InpTrailLock_H4);
   if(InpUseRatchetTrail)
      TrailStopsRatchet(InpMagic_M5);

   CancelStalePending(InpMagic_M15, PERIOD_M15, InpMaxWaitBars_M15);
   CancelStalePending(InpMagic_M30, PERIOD_M30, InpMaxWaitBars_M30);
   CancelStalePending(InpMagic_H4, PERIOD_H4, InpMaxWaitBars_H4);
  }
//+------------------------------------------------------------------+
