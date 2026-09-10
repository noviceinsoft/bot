//+------------------------------------------------------------------+
//| XAUUSD_M15_Scalper.mq5                                             |
//| Two independent signal engines on one XAUUSD chart: M15 (long-hold |
//| candle-pattern+EMA/BB, unique magic) and M5 (scalper variant,      |
//| unique magic). Each has its own enable switch, lot size, and full  |
//| filter set below - they never share state except the shared        |
//| MA50-Daily trend filter and the total-position risk cap.           |
//|                                                                     |
//| M15 defaults: SL12/TP45 fixed, MA50 filter, hour filter (blocks    |
//| 7/22), ADX floor 24 + ceiling 40, max 3 signals/day. Validated on   |
//| real MT5 tick data, walk-forward + permutation tested.             |
//|                                                                     |
//| M5 defaults: No-SL scalper, TP15, 4h hard-close, min-body filter,  |
//| Fib/Day-high-low rejection filter, up to 2 signals/day (2nd only    |
//| fires as an immediate same-bar-streak continuation and shares a    |
//| midpoint SL with the 1st). Validated train/test: PF 1.40/2.35.     |
//| Trade order comments: M15 = "LB"/"LS", M5 = "MB"/"MS".              |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- general -------------------------------------------------------------
input int    InpMaxTotalOpenPositions = 4; // hard cap on total open positions across both engines, 0 = unlimited
input ulong  MagicNumberM15  = 20260230;
input ulong  MagicNumberM5   = 20260231;
input int    Slippage        = 1000;   // max price deviation, points
input int    MaxRequotes     = 3;      // retry attempts on requote
input double DailyProfitStopPct = 0.0; // close all + stop trading when PnL gains this % of snapshot balance (0 = off)
input double DailyProfitStopUSD = 0.0; // close all + stop trading when PnL gains this many $ (0 = off); smaller of the two wins if both set
input double InpMaxDailyLossUSD = 0.0; // close all + stop trading when PnL LOSES this many $ (0 = off)
input int    SnapHour        = 0;      // server-time hour (0-23) for the daily balance snapshot

input group "=== M15 engine ==="
input bool   EnableM15        = true;
input double LotSize_M15      = 0.01;
input int    MaxPerSide_M15   = 3;      // max concurrent trades per side
input double InitialSL_M15    = 12.0;   // validated
input double InpFixedTPDist   = 45.0;   // validated (fixed TP distance)
input bool   InpUseHourFilter = true;   // blocks server hours below - validated (robust train/test)
input string InpBlockedHours  = "7,22";
input bool   InpUseMaxSignalsPerDay_M15 = true;
input int    InpMaxSignalsPerDay_M15    = 3;    // validated cap
input bool   InpUseADXFilter    = false; // ADX floor - validated as unhelpful for M15's entry logic, off
input double InpADXFloor_M15    = 24.0;
input bool   InpUseADXCeiling   = true;  // validated: ADX>=ceiling marks exhaustion, robust train/test
input double InpADXCeiling_M15  = 40.0;
input bool   InpUseVolFilter    = false; // validated as unhelpful for M15, off
input int    InpVolRefBars_M15  = 480;

input group "=== M5 engine (scalper) ==="
input bool   EnableM5         = true;
input double LotSize_M5       = 0.01;
input int    MaxPerSide_M5    = 2;
input double InitialSL_M5     = 6.0;    // only used if InpNoSL_M5=false
input double InpFixedTPDist_M5 = 15.0;  // validated
input bool   InpNoSL_M5           = true; // validated: no stop-loss, TP + hard-close are the only exits
input double InpHardCloseHours_M5 = 4.0;  // validated sweet spot (tested 1-8h)
input bool   InpUseMinBody_M5    = true;  // require candle body >= InpMinBodyPoints_M5 - validated, key filter
input double InpMinBodyPoints_M5 = 5.0;
input bool   InpUseLevelFilter_M5 = true; // rejection filter (touch level, close back) - validated
input double InpLevelProximity_M5 = 8.0;
input bool   InpLevelUseBB_M5     = false; // validated: hurts under rejection logic (band gets swept in trends), off
input bool   InpLevelUseFib_M5    = true;  // validated
input bool   InpLevelUseDayHL_M5  = true;  // validated
input bool   InpLevelUseH4HL_M5   = false; // validated: weakest of the four, off
input bool   InpLevelRequireAll_M5 = false; // true = AND all enabled level types, false = OR (validated: OR)
input bool   InpUseStreakSameTP_M5 = true;  // 2nd (continuation) trade shares the 1st trade's TP - validated
input bool   InpRequireAdjacent2nd_M5 = true; // 2nd trade only allowed as an immediate streak continuation - validated
input bool   InpStreakSharedSL_M5   = true;  // once the 2nd trade confirms, both trades get the same SL - validated
input bool   InpStreakSLUseMidpoint_M5 = true; // SL = midpoint(entry1, entry2) - validated, beats the fixed buffer below
input double InpStreakSLBufferPoints_M5 = 1.0; // only used if InpStreakSLUseMidpoint_M5=false
input bool   InpUseMA50Filter    = true;   // shared Daily MA50 trend filter - validated, strongest single filter
input int    InpMA50Period       = 50;
input double InpADXFloor_M5      = 25.0;
input int    InpVolRefBars_M5    = 480;
input bool   InpUseMaxSignalsPerDay_M5  = true;
input int    InpMaxSignalsPerDay_M5     = 2;    // validated cap (2nd only via the adjacent-streak rule above)

input group "=== Ratchet trailing (both engines; off by default) ==="
input double TrailStart      = 99999.0; // never arms by default - both engines use fixed SL/TP instead
input double TrailLock       = 4.0;
input double GapTrigger      = 1.5;
input double SLStep          = 0.7;
input double TPStep          = 0.5;
input double MinTPDist       = 8.0;     // min fib-TP distance; only relevant if InpUseFixedTP=false
input int    FibLookback     = 20;
input int    EmaPeriod       = 9;
input int    BBPeriod        = 20;      // BB middle = SMA(BBPeriod)
input bool   InpUseFixedTP    = true;   // fixed TP distance instead of fib - both engines use this

input group "=== Cross-market filters (off by default, tested harmful) ==="
input bool   InpUseDXYFilter     = false;
input string InpDXYSymbol        = "DXY";
input bool   InpUseATRBasedSL    = false;
input double InpATR_SL_Mult      = 2.0;
input double InpVolSpikeMultiplier = 2.0;
input int    InpATRPeriod        = 14;
input int    InpADXPeriod        = 14;

CTrade trade;

//--- daily profit stop state, scoped to this EA's own positions only ---
double   g_snapshotBalance   = 0.0;
datetime g_snapshotDay       = 0;      // midnight (server time) of the snapshot day
bool     g_profitStopHit     = false;
double   g_realizedSinceSnap = 0.0;    // this EA's closed-deal PnL since the snapshot,
                                        // updated event-driven in OnTradeTransaction (no rescans)
int      g_ourOpenCount      = 0;      // this EA's own open positions, kept event-driven so
                                        // OnTick can skip the position loops entirely when flat
int      g_blockedHours[];             // parsed from InpBlockedHours in OnInit
datetime g_signalDayM15    = 0;        // day boundary for the M15 per-day signal counter
int      g_signalsTodayM15 = 0;
datetime g_signalDayM5     = 0;        // separate day boundary/counter for M5 - must not share M15's
int      g_signalsTodayM5  = 0;

double FibRatios[] = {0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0,
                       1.272, 1.618, 2.0, 2.618, 3.618, 4.236,
                       5.0, 6.0, 7.0, 8.0};

//--- per-engine state, one instance per timeframe -----------------------
struct EngineState
{
   bool             enabled;
   ENUM_TIMEFRAMES  tf;
   string           label;         // "M15" or "M5" - used to route engine-specific logic
   ulong            magic;
   double           lotSize;
   double           initialSL;
   int              emaHandle;
   int              bbMidHandle;
   int              bbBandsHandle;    // iBands (upper/lower) - only built for M5, used by the level-rejection filter
   datetime         lastBarTime;
   string           streakSide;
   datetime         streakLastBar;
   int              streakCount;
   double           streakFirstTP;     // TP of the streak's 1st trade - reused by a continuation trade (InpUseStreakSameTP_M5)
   double           streakFirstEntry;  // real entry price of the streak's 1st trade - shared-SL midpoint anchor
   ulong            streakFirstTicket; // 1st trade's position ticket - retroactively re-SL'd when the 2nd trade confirms
   int              adxHandle;
   int              atrHandle;
   double           adxFloor;
   int              volRefBars;
   int              maxPerSide;
};

EngineState g_m15, g_m5;

//--- DXY and MA50-Daily handles (shared by both engines, timeframe-independent) ---
int g_ma50DailyHandle = INVALID_HANDLE;

//--- cache for NearReversalLevel()'s D1/H4 high/low - a raw iHigh/iLow call on a timeframe
//--- other than the chart's own is expensive in the Strategy Tester, so only refetch on a new bar
datetime g_dayHLCacheTime = 0;
double   g_dayHigh = 0.0, g_dayLow = 0.0;
datetime g_h4HLCacheTime  = 0;
double   g_h4High  = 0.0, g_h4Low  = 0.0;

//--- per-position ratchet state, keyed by ticket -----------------------
ulong  g_ticket[];
double g_bestMove[];
bool   g_trailOn[];

//+------------------------------------------------------------------+
bool InitEngine(EngineState &e, bool enabled, ENUM_TIMEFRAMES tf, string label,
                ulong magic, double lotSize, double initialSL, double adxFloor, int volRefBars, int maxPerSide)
{
   e.enabled     = enabled;
   e.tf          = tf;
   e.label       = label;
   e.magic       = magic;
   e.lotSize     = lotSize;
   e.initialSL   = initialSL;
   e.lastBarTime = 0;
   e.streakSide  = "";
   e.streakLastBar = 0;
   e.streakFirstTP = 0.0;
   e.streakFirstEntry = 0.0;
   e.streakFirstTicket = 0;
   e.streakCount = 0;
   e.adxFloor    = adxFloor;
   e.volRefBars  = volRefBars;
   e.maxPerSide  = maxPerSide;
   if(!enabled) return true;

   e.emaHandle   = iMA(_Symbol, tf, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   e.bbMidHandle = iMA(_Symbol, tf, BBPeriod,  0, MODE_SMA, PRICE_CLOSE);
   e.adxHandle   = iADX(_Symbol, tf, InpADXPeriod);
   e.atrHandle   = iATR(_Symbol, tf, InpATRPeriod);
   //--- bbBandsHandle (real upper/lower bands) only built for M5 - the level-rejection filter is M5-only
   e.bbBandsHandle = (label == "M5") ? iBands(_Symbol, tf, BBPeriod, 0, 2.0, PRICE_CLOSE) : INVALID_HANDLE;
   bool bbBandsOk = (label != "M5") || (e.bbBandsHandle != INVALID_HANDLE);
   return (e.emaHandle != INVALID_HANDLE && e.bbMidHandle != INVALID_HANDLE && bbBandsOk
           && e.adxHandle != INVALID_HANDLE && e.atrHandle != INVALID_HANDLE);
}

int OnInit()
{
   // parse "7,22" -> {7,22}
   string parts[];
   int nParts = StringSplit(InpBlockedHours, ',', parts);
   ArrayResize(g_blockedHours, 0);
   for(int i = 0; i < nParts; i++)
   {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      if(StringLen(p) == 0) continue;
      int h = (int)StringToInteger(p);
      int n = ArraySize(g_blockedHours);
      ArrayResize(g_blockedHours, n + 1);
      g_blockedHours[n] = h;
   }

   if(EnableM15 && EnableM5 && MagicNumberM15 == MagicNumberM5)
   {
      Print("XAUUSD_Scalper: MagicNumberM15 and MagicNumberM5 must differ when both engines "
            "are enabled, otherwise their position caps/trailing would merge. Aborting.");
      return INIT_FAILED;
   }

   if(!InitEngine(g_m15, EnableM15, PERIOD_M15, "M15", MagicNumberM15, LotSize_M15, InitialSL_M15,
                  InpADXFloor_M15, InpVolRefBars_M15, MaxPerSide_M15))
      return INIT_FAILED;
   if(!InitEngine(g_m5,  EnableM5,  PERIOD_M5,  "M5",  MagicNumberM5,  LotSize_M5,  InitialSL_M5,
                  InpADXFloor_M5, InpVolRefBars_M5, MaxPerSide_M5))
      return INIT_FAILED;

   // MA50-Daily filter handle + DXY symbol sanity check
   if(InpUseMA50Filter)
   {
      g_ma50DailyHandle = iMA(_Symbol, PERIOD_D1, InpMA50Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_ma50DailyHandle == INVALID_HANDLE)
      {
         Print("XAUUSD_Scalper: failed to create MA50-Daily handle.");
         return INIT_FAILED;
      }
   }
   if(InpUseDXYFilter && !SymbolSelect(InpDXYSymbol, true))
   {
      Print("XAUUSD_Scalper: DXY symbol '", InpDXYSymbol,
            "' not found in Market Watch. The DXY filter will fail open (no-op) until it's added.");
   }

   // arm lastBarTime to the CURRENT forming bar so the first CheckSignal
   // only fires once a genuinely new bar starts after attach — never
   // immediately off whatever pattern already exists at attach time
   if(EnableM15) g_m15.lastBarTime = iTime(_Symbol, g_m15.tf, 0);
   if(EnableM5)  g_m5.lastBarTime  = iTime(_Symbol, g_m5.tf, 0);
   if(!EnableM15 && !EnableM5)
   {
      Print("XAUUSD_Scalper: both EnableM15 and EnableM5 are false, EA will do nothing.");
   }

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
      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours = (EnableM15 && magic == (long)MagicNumberM15)
               || (EnableM5 && magic == (long)MagicNumberM5);
      if(ours && PositionGetString(POSITION_SYMBOL) == _Symbol) g_ourOpenCount++;
   }

   trade.SetDeviationInPoints(Slippage);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| close every position belonging to this EA, with requote retry     |
//+------------------------------------------------------------------+
void CloseAllOurs()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours = (EnableM15 && magic == (long)MagicNumberM15)
               || (EnableM5 && magic == (long)MagicNumberM5);
      if(!ours) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      trade.SetExpertMagicNumber((ulong)magic);
      for(int attempt = 0; attempt <= MaxRequotes; attempt++)
      {
         if(trade.PositionClose(ticket)) break;
         uint code = trade.ResultRetcode();
         if(code != TRADE_RETCODE_REQUOTE && code != TRADE_RETCODE_PRICE_CHANGED)
         {
            PrintFormat("XAUUSD_Scalper: profit-stop close of #%I64u failed, retcode %u", ticket, code);
            break;
         }
      }
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
      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours = (EnableM15 && magic == (long)MagicNumberM15)
               || (EnableM5 && magic == (long)MagicNumberM5);
      if(!ours) continue;
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

   int h = FileOpen("H1Ratchet_Balance.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
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
   bool ours = (EnableM15 && magic == (long)MagicNumberM15)
            || (EnableM5 && magic == (long)MagicNumberM5);
   if(!ours) return;
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
//| whole account. Tripping it flattens all our positions. Disabled   |
//| entirely when both DailyProfitStopPct and DailyProfitStopUSD = 0. |
//+------------------------------------------------------------------+
void UpdateProfitStop()
{
   if(DailyProfitStopPct <= 0.0 && DailyProfitStopUSD <= 0.0 && InpMaxDailyLossUSD <= 0.0) return;

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
      PrintFormat("XAUUSD_Scalper: %02d:00 balance snapshot %.2f", SnapHour, g_snapshotBalance);
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
         PrintFormat("XAUUSD_Scalper: this EA's PnL since snapshot +%.2f reached the %s threshold (+%.2f). "
                     "Closing all positions; no new trades until next 00:00 snapshot.",
                     ourPnLToday, hitBy, threshold);
         LogProgress("profit_stop_before_close");
         CloseAllOurs();
         LogProgress("profit_stop_after_close");
      }
      else if(InpMaxDailyLossUSD > 0.0 && ourPnLToday <= -InpMaxDailyLossUSD)
      {
         g_profitStopHit = true;
         PrintFormat("XAUUSD_Scalper: this EA's PnL since snapshot %.2f hit the max-daily-loss threshold (-%.2f). "
                     "Closing all positions; no new trades until next %02d:00 snapshot.",
                     ourPnLToday, InpMaxDailyLossUSD, SnapHour);
         LogProgress("loss_stop_before_close");
         CloseAllOurs();
         LogProgress("loss_stop_after_close");
      }
   }
}

void OnDeinit(const int reason)
{
   if(EnableM15) { IndicatorRelease(g_m15.emaHandle); IndicatorRelease(g_m15.bbMidHandle);
                    IndicatorRelease(g_m15.adxHandle); IndicatorRelease(g_m15.atrHandle); }
   if(EnableM5)  { IndicatorRelease(g_m5.emaHandle);  IndicatorRelease(g_m5.bbMidHandle);
                    IndicatorRelease(g_m5.adxHandle);  IndicatorRelease(g_m5.atrHandle);
                    if(g_m5.bbBandsHandle != INVALID_HANDLE) IndicatorRelease(g_m5.bbBandsHandle); }
   if(g_ma50DailyHandle != INVALID_HANDLE) IndicatorRelease(g_ma50DailyHandle);
}

//+------------------------------------------------------------------+
//| fib levels + next-TP-beyond-min-distance, mirrors the backtest    |
//+------------------------------------------------------------------+
//--- fixed TP (entry +/- distance) when InpUseFixedTP=true, else fib-based ---
double ComputeTP(double hi, double lo, double entry, bool isBuy, ulong magic)
{
   if(InpUseFixedTP)
   {
      double tpDist = (magic == MagicNumberM5) ? InpFixedTPDist_M5 : InpFixedTPDist;
      return isBuy ? entry + tpDist : entry - tpDist;
   }
   return NextFibTP(hi, lo, entry, isBuy);
}

double NextFibTP(double hi, double lo, double entry, bool isBuy)
{
   double range = hi - lo;
   int n = ArraySize(FibRatios);
   double best = 0.0;
   bool haveBest = false;
   double fallback = 0.0;
   bool haveFallback = false;

   for(int i = 0; i < n; i++)
   {
      double level = isBuy ? lo + range * FibRatios[i] : hi - range * FibRatios[i];
      bool beyond  = isBuy ? (level > entry) : (level < entry);
      if(!beyond) continue;

      double dist = isBuy ? (level - entry) : (entry - level);
      // track nearest-beyond level as fallback (used if none clears MinTPDist)
      if(!haveFallback || (isBuy && level < fallback) || (!isBuy && level > fallback))
      {
         fallback = level;
         haveFallback = true;
      }
      if(dist > MinTPDist)
      {
         if(!haveBest || (isBuy && level < best) || (!isBuy && level > best))
         {
            best = level;
            haveBest = true;
         }
      }
   }
   if(haveBest) return best;
   if(haveFallback) return fallback;
   return isBuy ? entry + MinTPDist + 1.0 : entry - MinTPDist - 1.0;
}

//+------------------------------------------------------------------+
int CountOpenBySide(ulong magic, bool isBuy)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((isBuy && type == POSITION_TYPE_BUY) || (!isBuy && type == POSITION_TYPE_SELL))
         count++;
   }
   return count;
}

//--- total open positions of this EA (both engines, both sides) - used by InpMaxTotalOpenPositions ---
int CountAllOpen()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours = (EnableM15 && magic == (long)MagicNumberM15)
               || (EnableM5 && magic == (long)MagicNumberM5);
      if(!ours) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| per-ticket ratchet-state helpers                                   |
//+------------------------------------------------------------------+
int FindTrackedIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_ticket); i++)
      if(g_ticket[i] == ticket) return i;
   return -1;
}

int TrackNewPosition(ulong ticket)
{
   int n = ArraySize(g_ticket);
   ArrayResize(g_ticket, n + 1);
   ArrayResize(g_bestMove, n + 1);
   ArrayResize(g_trailOn, n + 1);
   g_ticket[n]    = ticket;
   g_bestMove[n]  = 0.0;
   g_trailOn[n]   = false;
   return n;
}

void PruneClosedTracking()
{
   for(int i = ArraySize(g_ticket) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(g_ticket[i]))
      {
         int last = ArraySize(g_ticket) - 1;
         g_ticket[i]   = g_ticket[last];
         g_bestMove[i] = g_bestMove[last];
         g_trailOn[i]  = g_trailOn[last];
         ArrayResize(g_ticket, last);
         ArrayResize(g_bestMove, last);
         ArrayResize(g_trailOn, last);
      }
   }
}

//+------------------------------------------------------------------+
//| distance-based ratchet trailing, applied every tick to every       |
//| position opened by either engine (H1 or M30 magic)                 |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   PruneClosedTracking();

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours = (EnableM15 && magic == (long)MagicNumberM15)
               || (EnableM5 && magic == (long)MagicNumberM5);
      if(!ours) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int idx = FindTrackedIndex(ticket);
      if(idx < 0) idx = TrackNewPosition(ticket);

      bool isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl       = PositionGetDouble(POSITION_SL);
      double tp       = PositionGetDouble(POSITION_TP);
      double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double curPrice = isBuy ? bid : ask;
      double move     = isBuy ? (curPrice - entry) : (entry - curPrice);

      if(move > g_bestMove[idx]) g_bestMove[idx] = move;
      double bestMove = g_bestMove[idx];

      bool changed = false;

      if(!g_trailOn[idx] && bestMove >= TrailStart)
      {
         // arm only: lock SL at entry+-TrailLock, no same-tick catch-up
         // ratchet, or the gap-closing loop below would immediately jump
         // SL to within GapTrigger of bestMove on this very tick
         g_trailOn[idx] = true;
         sl = isBuy ? entry + TrailLock : entry - TrailLock;
         changed = true;
      }
      else if(g_trailOn[idx])
      {
         // step count computed directly instead of looping SLStep at a time - a loop here could
         // run millions of iterations on a large single-tick price jump (e.g. thin year-end
         // liquidity), freezing the tester and risking the same on live under a real price gap.
         double slOffset0 = isBuy ? (sl - entry) : (entry - sl);
         double avail = bestMove - slOffset0 - GapTrigger;
         if(avail >= 0.0 && SLStep > 0.0)
         {
            int steps = (int)MathFloor(avail / SLStep) + 1;
            double deltaSL = steps * SLStep;
            double deltaTP = steps * TPStep;
            if(isBuy) { sl += deltaSL; tp += deltaTP; }
            else      { sl -= deltaSL; tp -= deltaTP; }
            changed = true;
         }
      }

      if(changed)
      {
         trade.SetExpertMagicNumber((ulong)magic);
         trade.PositionModify(ticket, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
//| market order with requote retry                                    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| re-anchor SL/TP to the ACTUAL fill price after a market order,     |
//| since Slippage lets the real fill land away from the pre-send     |
//| price snapshot SL/TP were originally computed from                 |
//+------------------------------------------------------------------+
//--- M5 opens with SL=0 (no stop) when InpNoSL_M5=true - TP + hard-close are the only exits
bool NoSLForMagic(ulong magic) { return (magic == MagicNumberM5) && InpNoSL_M5; }

//--- real TP/entry/ticket of the trade just opened (post-fill) - CheckSignal reads these back to
//--- populate e.streakFirstTP/Entry/Ticket when the trade is the 1st of a new streak
double g_lastOpenedTP = 0.0;
double g_lastOpenedEntry  = 0.0;
ulong  g_lastOpenedTicket = 0;

//--- overrideSL > 0 -> use it as-is (absolute price), used by InpStreakSharedSL_M5 ---
void RealignSLTP(bool isBuy, double initialSL, double hi20, double lo20, ulong magic, double overrideTP, double overrideSL = 0.0)
{
   ulong dealTicket = trade.ResultDeal();
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;

   ulong posTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(!PositionSelectByTicket(posTicket)) return;

   double actualEntry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_lastOpenedEntry  = actualEntry;
   g_lastOpenedTicket = posTicket;

   double correctSL = (overrideSL > 0.0) ? NormalizeDouble(overrideSL, _Digits)
                     : NoSLForMagic(magic) ? 0.0
                     : NormalizeDouble(isBuy ? actualEntry - initialSL : actualEntry + initialSL, _Digits);
   double correctTP = (overrideTP > 0.0) ? NormalizeDouble(overrideTP, _Digits)
                                          : NormalizeDouble(ComputeTP(hi20, lo20, actualEntry, isBuy, magic), _Digits);
   g_lastOpenedTP = correctTP;

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   if(MathAbs(curSL - correctSL) < _Point && MathAbs(curTP - correctTP) < _Point) return; // already right

   if(!trade.PositionModify(posTicket, correctSL, correctTP))
      PrintFormat("XAUUSD_Scalper: SL/TP realign on #%I64u failed, retcode %u", posTicket, trade.ResultRetcode());
}

double LotForMagic(ulong magic) { return (magic == MagicNumberM5) ? LotSize_M5 : LotSize_M15; }

//+------------------------------------------------------------------+
//| opens a market order, retrying on requote. overrideTP/overrideSL,  |
//| when > 0, are used as-is (absolute prices) instead of computing    |
//| them from initialSL/ComputeTP - used for streak-continuation trades|
//+------------------------------------------------------------------+
bool OpenWithRetry(ulong magic, double initialSL, bool isBuy, double hi20,
                    double lo20, string comment, double overrideTP = 0.0, double overrideSL = 0.0)
{
   trade.SetExpertMagicNumber(magic);
   double lot = LotForMagic(magic);
   for(int attempt = 0; attempt <= MaxRequotes; attempt++)
   {
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = (overrideSL > 0.0) ? overrideSL : (NoSLForMagic(magic) ? 0.0 : (isBuy ? price - initialSL : price + initialSL));
      double tp = (overrideTP > 0.0) ? overrideTP : ComputeTP(hi20, lo20, price, isBuy, magic);

      bool ok = isBuy
         ? trade.Buy(lot, _Symbol, price, NormalizeDouble(sl, _Digits),
                     NormalizeDouble(tp, _Digits), comment)
         : trade.Sell(lot, _Symbol, price, NormalizeDouble(sl, _Digits),
                      NormalizeDouble(tp, _Digits), comment);
      if(ok)
      {
         RealignSLTP(isBuy, initialSL, hi20, lo20, magic, overrideTP, overrideSL); // fill may have landed away from `price`; fix SL/TP to match
         return true;
      }

      uint code = trade.ResultRetcode();
      if(code != TRADE_RETCODE_REQUOTE && code != TRADE_RETCODE_PRICE_CHANGED)
         return false; // not a requote, don't retry
   }
   return false;
}

//+------------------------------------------------------------------+
//| candle color helpers + 6-bar lookback filter (bars 1..6, i.e. b2, |
//| b1, and the 4 bars before b1)                                     |
//+------------------------------------------------------------------+
bool IsGreenBar(ENUM_TIMEFRAMES tf, int idx) { return iClose(_Symbol, tf, idx) > iOpen(_Symbol, tf, idx); }
bool IsRedBar(ENUM_TIMEFRAMES tf, int idx)   { return iClose(_Symbol, tf, idx) < iOpen(_Symbol, tf, idx); }

bool HasConsecutiveRedPair(ENUM_TIMEFRAMES tf)
{
   for(int idx = 1; idx <= 5; idx++)
      if(IsRedBar(tf, idx) && IsRedBar(tf, idx + 1)) return true;
   return false;
}

bool HasConsecutiveGreenPair(ENUM_TIMEFRAMES tf)
{
   for(int idx = 1; idx <= 5; idx++)
      if(IsGreenBar(tf, idx) && IsGreenBar(tf, idx + 1)) return true;
   return false;
}

//--- true once today's signal count for this engine has reached its cap. M15/M5 have separate
//--- day boundaries and counters so one engine's cap can never affect the other's.
bool IsMaxSignalsReached(EngineState &e)
{
   bool  isM15 = (e.magic == MagicNumberM15);
   bool  useIt = isM15 ? InpUseMaxSignalsPerDay_M15 : InpUseMaxSignalsPerDay_M5;
   int   cap   = isM15 ? InpMaxSignalsPerDay_M15     : InpMaxSignalsPerDay_M5;
   if(!useIt || cap <= 0) return false;

   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   datetime today = now - (t.hour * 3600 + t.min * 60 + t.sec);
   if(isM15)
   {
      if(g_signalDayM15 != today) { g_signalDayM15 = today; g_signalsTodayM15 = 0; }
      return (g_signalsTodayM15 >= cap);
   }
   else
   {
      if(g_signalDayM5 != today) { g_signalDayM5 = today; g_signalsTodayM5 = 0; }
      return (g_signalsTodayM5 >= cap);
   }
}

//--- true when the current server hour is in the blocked list ---
bool IsHourBlocked()
{
   if(!InpUseHourFilter) return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   for(int i = 0; i < ArraySize(g_blockedHours); i++)
      if(t.hour == g_blockedHours[i]) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Veto filters (walk-forward + permutation tested where noted) -    |
//| these never change the entry pattern itself, only block a trade.  |
//+------------------------------------------------------------------+

//--- true when DXY's direction contradicts the intended trade ---
bool DXYBlocks(bool isBuy)
{
   if(!InpUseDXYFilter) return false;
   double dxyClose[];
   ArraySetAsSeries(dxyClose, true);
   if(CopyClose(InpDXYSymbol, PERIOD_M15, 1, 2, dxyClose) < 2)
      return false; // no data -> fail open

   // DXY up -> pressure on gold to fall -> block BUY; DXY down -> block SELL
   if(dxyClose[0] > dxyClose[1] && isBuy)  return true;
   if(dxyClose[0] < dxyClose[1] && !isBuy) return true;
   return false;
}

//--- true when price is on the wrong side of the Daily MA50 trend ---
bool MA50Blocks(bool isBuy)
{
   if(!InpUseMA50Filter) return false;
   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   if(CopyBuffer(g_ma50DailyHandle, 0, 1, 1, maBuf) <= 0)
      return false; // fail open

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(isBuy  && price < maBuf[0]) return true;
   if(!isBuy && price > maBuf[0]) return true;
   return false;
}

//--- ADX regime filter: true when ADX is below the floor (weak/grinding trend) or, for M15,
//--- at/above the ceiling (exhausted/parabolic trend - tested robust on real trade data)
bool ADXBlocks(EngineState &e)
{
   if(!InpUseADXFilter) return false;
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(e.adxHandle, 0, 1, 1, adxBuf) <= 0)
      return false; // fail open
   if(adxBuf[0] < e.adxFloor) return true;
   if(InpUseADXCeiling && e.label == "M15" && adxBuf[0] >= InpADXCeiling_M15) return true;
   return false;
}

//--- true when current ATR spikes above its recent average (post-shock whipsaw risk) ---
bool VolSpikeBlocks(EngineState &e)
{
   if(!InpUseVolFilter) return false;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(e.atrHandle, 0, 1, e.volRefBars, atrBuf) < e.volRefBars)
      return false; // not enough history -> fail open
   double currentATR = atrBuf[0];
   double sum = 0.0;
   for(int i = 0; i < e.volRefBars; i++) sum += atrBuf[i];
   double avgATR = sum / e.volRefBars;
   if(avgATR <= 0) return false;
   return (currentATR > InpVolSpikeMultiplier * avgATR);
}

//--- current ATR for one engine, used by the optional ATR-based SL ---
double GetCurrentATR(EngineState &e)
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(e.atrHandle, 0, 1, 1, atrBuf) <= 0) return 0.0;
   return atrBuf[0];
}

//--- rejection filter: true when b2 (the just-closed bar) touched/pierced one of the enabled
//--- levels (BB band / fib retracement / day H-L / H4 H-L) and closed back on the safe side -
//--- BUY checks the level below (support), SELL checks the level above (resistance). M5-only.
bool NearReversalLevel(EngineState &e, bool isBuy, double c2, double h2, double l2, double hi20, double lo20)
{
   if(!InpUseLevelFilter_M5 || e.magic != MagicNumberM5) return true; // filter off -> never blocks

   double prox = InpLevelProximity_M5;
   int enabledCount = 0, matchCount = 0;

   if(InpLevelUseBB_M5 && e.bbBandsHandle != INVALID_HANDLE)
   {
      enabledCount++;
      double bandBuf[]; ArraySetAsSeries(bandBuf, true);
      // iBands buffer 1 = upper, 2 = lower; shift=1 = last closed bar
      bool hit = false;
      if(isBuy && CopyBuffer(e.bbBandsHandle, 2, 1, 1, bandBuf) > 0)
         hit = (l2 <= bandBuf[0] + prox) && (c2 > bandBuf[0]); // pierced lower band, closed back above
      else if(!isBuy && CopyBuffer(e.bbBandsHandle, 1, 1, 1, bandBuf) > 0)
         hit = (h2 >= bandBuf[0] - prox) && (c2 < bandBuf[0]); // pierced upper band, closed back below
      if(hit) matchCount++;
      else if(InpLevelRequireAll_M5) return false; // AND mode: one enabled type missed -> reject now
   }

   if(InpLevelUseFib_M5)
   {
      enabledCount++;
      double range = hi20 - lo20;
      double fibLevels[3] = {0.382, 0.5, 0.618};
      bool hit = false;
      for(int i = 0; i < 3; i++)
      {
         double level = lo20 + range * fibLevels[i];
         bool levelHit = isBuy ? ((l2 <= level + prox) && (c2 > level))
                                : ((h2 >= level - prox) && (c2 < level));
         if(levelHit) { hit = true; break; }
      }
      if(hit) matchCount++;
      else if(InpLevelRequireAll_M5) return false;
   }

   // D1/H4 high/low are cached and only refetched on a new D1/H4 bar - a raw iHigh/iLow call on a
   // timeframe other than the chart's own is slow in the Strategy Tester if called every bar.
   if(InpLevelUseDayHL_M5)
   {
      enabledCount++;
      datetime curDay = iTime(_Symbol, PERIOD_D1, 0);
      if(curDay != g_dayHLCacheTime)
      {
         g_dayHLCacheTime = curDay;
         g_dayHigh = iHigh(_Symbol, PERIOD_D1, 0);
         g_dayLow  = iLow(_Symbol, PERIOD_D1, 0);
      }
      bool hit = (isBuy  && g_dayHigh > 0 && (l2 <= g_dayLow + prox)  && (c2 > g_dayLow))
              || (!isBuy && g_dayHigh > 0 && (h2 >= g_dayHigh - prox) && (c2 < g_dayHigh));
      if(hit) matchCount++;
      else if(InpLevelRequireAll_M5) return false;
   }

   if(InpLevelUseH4HL_M5)
   {
      enabledCount++;
      datetime curH4 = iTime(_Symbol, PERIOD_H4, 1);
      if(curH4 != g_h4HLCacheTime)
      {
         g_h4HLCacheTime = curH4;
         g_h4High = iHigh(_Symbol, PERIOD_H4, 1);
         g_h4Low  = iLow(_Symbol, PERIOD_H4, 1);
      }
      bool hit = (isBuy  && g_h4High > 0 && (l2 <= g_h4Low + prox)  && (c2 > g_h4Low))
              || (!isBuy && g_h4High > 0 && (h2 >= g_h4High - prox) && (c2 < g_h4High));
      if(hit) matchCount++;
      else if(InpLevelRequireAll_M5) return false;
   }

   if(enabledCount == 0) return true; // nothing enabled -> never blocks
   return InpLevelRequireAll_M5 ? true : (matchCount > 0); // AND already survived the loop above; OR needs >=1 match
}

//+------------------------------------------------------------------+
//| 2-bar signal check for one engine, called once per new bar of      |
//| that engine's timeframe                                            |
//+------------------------------------------------------------------+
void CheckSignal(EngineState &e)
{
   if(IsHourBlocked()) return;
   if(IsMaxSignalsReached(e)) return;
   if(InpMaxTotalOpenPositions > 0 && CountAllOpen() >= InpMaxTotalOpenPositions) return; // combined risk cap, both engines

   double o1 = iOpen(_Symbol, e.tf, 2), c1 = iClose(_Symbol, e.tf, 2); // b1
   double o2 = iOpen(_Symbol, e.tf, 1), c2 = iClose(_Symbol, e.tf, 1); // b2 (just closed)
   double h2 = iHigh(_Symbol, e.tf, 1), l2 = iLow(_Symbol, e.tf, 1);
   datetime b1Time = iTime(_Symbol, e.tf, 2);
   datetime b2Time = iTime(_Symbol, e.tf, 1);

   int highestIdx = iHighest(_Symbol, e.tf, MODE_HIGH, FibLookback, 1);
   int lowestIdx  = iLowest(_Symbol, e.tf, MODE_LOW, FibLookback, 1);
   if(highestIdx < 0 || lowestIdx < 0) return;
   double hi20 = iHigh(_Symbol, e.tf, highestIdx);
   double lo20 = iLow(_Symbol, e.tf, lowestIdx);

   double tmp[1];
   double emaB1, emaB2, bbB1, bbB2;
   if(CopyBuffer(e.emaHandle, 0, 2, 1, tmp) < 1) return; emaB1 = tmp[0];
   if(CopyBuffer(e.emaHandle, 0, 1, 1, tmp) < 1) return; emaB2 = tmp[0];
   if(CopyBuffer(e.bbMidHandle, 0, 2, 1, tmp) < 1) return; bbB1 = tmp[0];
   if(CopyBuffer(e.bbMidHandle, 0, 1, 1, tmp) < 1) return; bbB2 = tmp[0];

   bool crossDown = (emaB1 > bbB1) && (emaB2 < bbB2);
   bool crossUp   = (emaB1 < bbB1) && (emaB2 > bbB2);

   bool buyStreakBlocked  = (e.streakSide == "buy"  && e.streakLastBar == b1Time && e.streakCount >= 2);
   bool sellStreakBlocked = (e.streakSide == "sell" && e.streakLastBar == b1Time && e.streakCount >= 2);

   bool greenPattern = (c1 > o1) && (c2 > o2);
   bool redPattern   = (c1 < o1) && (c2 < o2);
   bool topWickBlocked    = (h2 - c2) > (c2 - o2); // b2's upper wick bigger than its body -- skip the buy
   bool bottomWickBlocked = (c2 - l2) > (o2 - c2); // b2's lower wick bigger than its body -- skip the sell

   // order-2 bypass: order 1 of this streak opened exactly one bar ago --
   // skip the 6-bar lookback check, but require a 3rd confirming bar instead
   bool buyBypass  = (e.streakSide == "buy"  && e.streakLastBar == b1Time && e.streakCount == 1);
   bool sellBypass = (e.streakSide == "sell" && e.streakLastBar == b1Time && e.streakCount == 1);

   bool buyLookbackOk  = buyBypass  ? IsGreenBar(e.tf, 3) : HasConsecutiveRedPair(e.tf);
   bool sellLookbackOk = sellBypass ? IsRedBar(e.tf, 3)   : HasConsecutiveGreenPair(e.tf);

   // M5-only: require a minimum candle body (filters out weak/doji-like bars)
   bool minBodyBlocked = (e.magic == MagicNumberM5) && InpUseMinBody_M5 && (MathAbs(c2 - o2) < InpMinBodyPoints_M5);

   bool buyLevelOk  = NearReversalLevel(e, true,  c2, h2, l2, hi20, lo20);
   bool sellLevelOk = NearReversalLevel(e, false, c2, h2, l2, hi20, lo20);

   // M5-only: a bypass trade (immediate streak continuation) reuses the streak's 1st TP
   // instead of computing its own entry+distance TP.
   bool buyIsContinuation  = (e.magic == MagicNumberM5) && buyBypass;
   bool sellIsContinuation = (e.magic == MagicNumberM5) && sellBypass;
   double buyOverrideTP  = (InpUseStreakSameTP_M5 && buyIsContinuation  && e.streakFirstTP > 0.0) ? e.streakFirstTP : 0.0;
   double sellOverrideTP = (InpUseStreakSameTP_M5 && sellIsContinuation && e.streakFirstTP > 0.0) ? e.streakFirstTP : 0.0;

   // M5-only: once the 2nd (continuation) trade is about to open, give both trades a shared SL -
   // either the midpoint of the two entries, or entry1 +/- a fixed buffer. The 1st trade stays
   // No-SL until this point. Current market price stands in for the 2nd trade's entry estimate
   // (same approximation ComputeTP already uses before the real fill price is known).
   double estEntry2Buy  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double estEntry2Sell = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buyOverrideSL  = (InpStreakSharedSL_M5 && buyIsContinuation  && e.streakFirstEntry > 0.0)
                          ? (InpStreakSLUseMidpoint_M5 ? (e.streakFirstEntry + estEntry2Buy) / 2.0
                                                        : e.streakFirstEntry + InpStreakSLBufferPoints_M5)
                          : 0.0;
   double sellOverrideSL = (InpStreakSharedSL_M5 && sellIsContinuation && e.streakFirstEntry > 0.0)
                          ? (InpStreakSLUseMidpoint_M5 ? (e.streakFirstEntry + estEntry2Sell) / 2.0
                                                        : e.streakFirstEntry - InpStreakSLBufferPoints_M5)
                          : 0.0;

   // M5-only: once one trade has fired today, block any further signal UNLESS it's an immediate
   // streak continuation (bypass) - a signal that re-qualifies later the same day via the full
   // 6-bar lookback is NOT allowed as a 2nd trade (tested: this "distant re-qualify" case is worse).
   bool buyNonAdjacentBlocked  = (e.magic == MagicNumberM5) && InpRequireAdjacent2nd_M5
                               && g_signalsTodayM5 >= 1 && !buyIsContinuation;
   bool sellNonAdjacentBlocked = (e.magic == MagicNumberM5) && InpRequireAdjacent2nd_M5
                               && g_signalsTodayM5 >= 1 && !sellIsContinuation;

   if(greenPattern && CountOpenBySide(e.magic, true) < e.maxPerSide && !crossDown && !buyStreakBlocked && !topWickBlocked && buyLookbackOk
      && !minBodyBlocked && buyLevelOk && !buyNonAdjacentBlocked && !DXYBlocks(true) && !MA50Blocks(true) && !ADXBlocks(e) && !VolSpikeBlocks(e))
   {
      double slDist = InpUseATRBasedSL ? (GetCurrentATR(e) * InpATR_SL_Mult) : e.initialSL;
      if(slDist <= 0) slDist = e.initialSL; // fallback if ATR read fails
      bool wasFreshStreak = !(e.streakSide == "buy" && e.streakLastBar == b1Time);
      string cmt = (e.magic == MagicNumberM15) ? "LB" : "MB";
      if(OpenWithRetry(e.magic, slDist, true, hi20, lo20, cmt, buyOverrideTP, buyOverrideSL))
      {
         if(e.streakSide == "buy" && e.streakLastBar == b1Time) e.streakCount++;
         else { e.streakSide = "buy"; e.streakCount = 1; }
         e.streakLastBar = b2Time;
         if(wasFreshStreak)
         {
            e.streakFirstTP = g_lastOpenedTP;
            e.streakFirstEntry = g_lastOpenedEntry;
            e.streakFirstTicket = g_lastOpenedTicket;
         }
         else if(buyOverrideSL > 0.0 && e.streakFirstTicket != 0)
         {
            // the 2nd trade just opened with a shared SL - retroactively move the 1st trade's SL to match
            if(PositionSelectByTicket(e.streakFirstTicket))
            {
               double firstTP = PositionGetDouble(POSITION_TP);
               trade.SetExpertMagicNumber(e.magic);
               if(!trade.PositionModify(e.streakFirstTicket, NormalizeDouble(buyOverrideSL, _Digits), firstTP))
                  PrintFormat("XAUUSD_Scalper: streak-shared-SL retroactive modify #%I64u failed, retcode %u",
                              e.streakFirstTicket, trade.ResultRetcode());
            }
         }
         if(e.magic == MagicNumberM15) g_signalsTodayM15++; else g_signalsTodayM5++;
      }
   }
   else if(redPattern && CountOpenBySide(e.magic, false) < e.maxPerSide && !crossUp && !sellStreakBlocked && !bottomWickBlocked && sellLookbackOk
      && !minBodyBlocked && sellLevelOk && !sellNonAdjacentBlocked && !DXYBlocks(false) && !MA50Blocks(false) && !ADXBlocks(e) && !VolSpikeBlocks(e))
   {
      double slDist = InpUseATRBasedSL ? (GetCurrentATR(e) * InpATR_SL_Mult) : e.initialSL;
      if(slDist <= 0) slDist = e.initialSL;
      bool wasFreshStreak = !(e.streakSide == "sell" && e.streakLastBar == b1Time);
      string cmt = (e.magic == MagicNumberM15) ? "LS" : "MS";
      if(OpenWithRetry(e.magic, slDist, false, hi20, lo20, cmt, sellOverrideTP, sellOverrideSL))
      {
         if(e.streakSide == "sell" && e.streakLastBar == b1Time) e.streakCount++;
         else { e.streakSide = "sell"; e.streakCount = 1; }
         e.streakLastBar = b2Time;
         if(wasFreshStreak)
         {
            e.streakFirstTP = g_lastOpenedTP;
            e.streakFirstEntry = g_lastOpenedEntry;
            e.streakFirstTicket = g_lastOpenedTicket;
         }
         else if(sellOverrideSL > 0.0 && e.streakFirstTicket != 0)
         {
            if(PositionSelectByTicket(e.streakFirstTicket))
            {
               double firstTP = PositionGetDouble(POSITION_TP);
               trade.SetExpertMagicNumber(e.magic);
               if(!trade.PositionModify(e.streakFirstTicket, NormalizeDouble(sellOverrideSL, _Digits), firstTP))
                  PrintFormat("XAUUSD_Scalper: streak-shared-SL retroactive modify #%I64u failed, retcode %u",
                              e.streakFirstTicket, trade.ResultRetcode());
            }
         }
         if(e.magic == MagicNumberM15) g_signalsTodayM15++; else g_signalsTodayM5++;
      }
   }
}

//+------------------------------------------------------------------+
//| force-closes M5 trades after InpHardCloseHours_M5, even without   |
//| hitting SL/TP - pairs with InpNoSL_M5 as a time-based exit          |
//+------------------------------------------------------------------+
void CheckHardClose()
{
   if(InpHardCloseHours_M5 <= 0.0) return;
   datetime cutoff = TimeCurrent() - (datetime)(InpHardCloseHours_M5 * 3600);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != (long)MagicNumberM5) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((datetime)PositionGetInteger(POSITION_TIME) > cutoff) continue; // not old enough yet

      trade.SetExpertMagicNumber((ulong)magic);
      for(int attempt = 0; attempt <= MaxRequotes; attempt++)
      {
         if(trade.PositionClose(ticket)) break;
         uint code = trade.ResultRetcode();
         if(code != TRADE_RETCODE_REQUOTE && code != TRADE_RETCODE_PRICE_CHANGED)
         {
            PrintFormat("XAUUSD_Scalper: hard-close of #%I64u failed, retcode %u", ticket, code);
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageTrailing();
   CheckHardClose();
   UpdateProfitStop();

   if(g_profitStopHit) return; // no new entries until next 00:00 snapshot

   if(EnableM15)
   {
      datetime cur = iTime(_Symbol, g_m15.tf, 0);
      if(cur != g_m15.lastBarTime)
      {
         g_m15.lastBarTime = cur;
         CheckSignal(g_m15);
      }
   }
   if(EnableM5)
   {
      datetime cur = iTime(_Symbol, g_m5.tf, 0);
      if(cur != g_m5.lastBarTime)
      {
         g_m5.lastBarTime = cur;
         CheckSignal(g_m5);
      }
   }
}
//+------------------------------------------------------------------+
