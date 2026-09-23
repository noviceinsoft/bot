//+------------------------------------------------------------------+
//|                                                  BB_H4_EA.mq5    |
//|  EA: Bollinger-band breakout, 6 timeframes, two signal families,  |
//|  each with a TP that re-pegs every bar (EMA-smoothed toward the   |
//|  latest close) instead of a fixed target -- and no SL.            |
//|                                                                    |
//|  Variables: x/x2 = upper/lower band point, solved exactly (see    |
//|  SolveBandPoint) for the self-consistent value the band would     |
//|  have if the forming bar closed at that price -- not the raw      |
//|  shift-0 snapshot taken at bar-open.                               |
//|                                                                    |
//|  ORIGINAL (THS/THB, InpUseOriginalEA):                            |
//|   THS: bid - x >= THS_Threshold_Units  -> Sell instant, TP = x.   |
//|   THB: x2 - ask >= THB_Threshold_Units -> Buy instant,  TP = x2.  |
//|                                                                    |
//|  ADDON (THS2/THB2, InpUseAddonEA) -- breakout-fade, limit entry:  |
//|   THS2: bar0.high-x>threshold AND bar0.close-x>=threshold         |
//|         -> Sell Limit at bar0.high, TP = x. Cancels if unfilled   |
//|         after 1 bar. THS2_ChaseAfterFill picks chase vs static.   |
//|   THB2: mirror, buy limit at bar0.low, TP = x2.                   |
//|                                                                    |
//|  TP chase (both families): every bar, TP moves toward the latest  |
//|  close by InpChaseFraction (or InpAddonChaseFraction for THS2/    |
//|  THB2) -- an EMA of price, so the price-to-TP gap tracks per-bar   |
//|  movement instead of growing with total distance since entry.     |
//|  If the chase can't legally move TP (wrong side of price) or the  |
//|  modify/close itself fails, the position is force-closed at       |
//|  market (or, if that also fails e.g. market briefly closed,       |
//|  tracking is kept and retried next bar rather than abandoned).    |
//|                                                                    |
//|  Per-TF isolation: Orig_M1..H4 / Addon_M1..H4 gate each signal     |
//|  family independently per timeframe, on top of the master         |
//|  switches and the blanket Enable_M1..H4.                          |
//|                                                                    |
//|  ONE EA instance runs all 6 timeframes together: M1 M5 M15 M30    |
//|  H1 H4, each with its own MagicNumber (must be unique) so         |
//|  positions/orders never mix between them.                         |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "5.00"
#property strict
#include <Trade\Trade.mqh>

CTrade trade; // used only for CloseAllOurs()/pending cancel; order opening below still uses raw OrderSend

//--- Timeframe slot indices
#define IDX_M1  0
#define IDX_M5  1
#define IDX_M15 2
#define IDX_M30 3
#define IDX_H1  4
#define IDX_H4  5
#define TF_COUNT 6

//--- Input parameters
input group "=== Tester CSV dump ==="
input string   InpCsvDumpName = "";                 // if set, OnTester writes deals to <name>.csv (Common\Files)
input bool     InpDebugNext2  = false;              // one-off: dump next-2-candle H/C vs TP for the 10 known losers
input bool     InpDebugBandSolve = false;           // log shift-0 snapshot vs solved band point every new bar (BB_bandsolve_debug.csv)
input group "=== Quadratic band TP-blend (per-TF, 0 = fully original snapshot behavior) ==="
input double   M1_TPBlendFrac  = 0.75;              // 0=original threshold+TP; >0=quadratic threshold, TP=baseline+frac*(quadratic-baseline). Sweet spot 0.75 for M1.
input double   M5_TPBlendFrac  = 0.0;
input double   M15_TPBlendFrac = 0.0;
input double   M30_TPBlendFrac = 0.0;
input double   H1_TPBlendFrac  = 0.0;
input double   H4_TPBlendFrac  = 0.0;
input int      InpMaxBarsHold = 0;                  // force-close if TP not touched after this many bars (0 = chase forever)
input double   InpChaseFraction = 0.6;              // TP EMA smoothing for THS/THB: TP = lastTp + frac*(newClose-lastTp) [sell] / lastTp - frac*(lastTp-newClose) [buy]
input double   InpAddonChaseFraction = 0.6666666667; // same EMA smoothing, but for THS2/THB2 fills
input double   InpHardSLUnits = 0;                  // fixed SL distance from entry, price units (0 = no SL)
input bool     InpUseBandChase = false;             // true: TP chases the live band value (y/y2) each bar instead of the EMA-fraction formula
input int      InpGlobalMaxConcurrent = 0;          // cap on open+pending positions across ALL 6 timeframes combined (0 = no cap, per-TF caps still apply)

input group "=== Timeframes ==="
input bool     Enable_M1   = true;                  // Run M1
input bool     Enable_M5   = true;                  // Run M5
input bool     Enable_M15  = true;                  // Run M15
input bool     Enable_M30  = true;                  // Run M30
input bool     Enable_H1   = true;                  // Run H1
input bool     Enable_H4   = false;                 // Run H4
input int      M1_Magic    = 111001;                // M1 magic (unique)
input int      M5_Magic    = 111005;                // M5 magic (unique)
input int      M15_Magic   = 111015;                // M15 magic (unique)
input int      M30_Magic   = 111030;                // M30 magic (unique)
input int      H1_Magic    = 111060;                // H1 magic (unique)
input int      H4_Magic    = 111240;                // H4 magic (unique)

input group "=== Trading Hours (server time, empty = all day) ==="
input string   M1_TradeHours  = "";                 // M1 hours e.g. "1-3,15-20"
input string   M5_TradeHours  = "";                 // M5 hours e.g. "1-3,15-20"
input string   M15_TradeHours = "";                 // M15 hours e.g. "1-3,15-20"
input string   M30_TradeHours = "";                 // M30 hours e.g. "1-3,15-20"
input string   H1_TradeHours  = "";                 // H1 hours e.g. "1-3,15-20"
input string   H4_TradeHours  = "";                 // H4 hours e.g. "1-3,15-20"

input group "=== Bollinger Band ==="
input int      BB_Period       = 20;                // Period
input double   BB_Deviation    = 2.0;                // Deviation
input ENUM_APPLIED_PRICE BB_Price = PRICE_CLOSE;     // Applied price

input group "=== Price Unit ==="
input double   PriceUnit       = 1.0;                // 1 unit = X price points

input group "=== Master switches ==="
input bool     InpUseOriginalEA = true;               // master: original THS/THB (instant market entries), all 6 TF
input bool     InpUseAddonEA    = true;                // master: THS2/THB2 fade addon (limit-order entries), all 6 TF

input group "=== Original (THS/THB) per-TF enable ==="
input bool     Orig_M1  = true;                       // Run THS/THB on M1
input bool     Orig_M5  = true;                       // Run THS/THB on M5
input bool     Orig_M15 = true;                       // Run THS/THB on M15
input bool     Orig_M30 = true;                       // Run THS/THB on M30
input bool     Orig_H1  = true;                       // Run THS/THB on H1
input bool     Orig_H4  = false;                      // Run THS/THB on H4

input group "=== Addon (THS2/THB2) per-TF enable ==="
input bool     Addon_M1  = false;                     // Run THS2/THB2 on M1
input bool     Addon_M5  = true;                      // Run THS2/THB2 on M5
input bool     Addon_M15 = true;                      // Run THS2/THB2 on M15
input bool     Addon_M30 = true;                      // Run THS2/THB2 on M30
input bool     Addon_H1  = true;                       // Run THS2/THB2 on H1
input bool     Addon_H4  = false;                      // Run THS2/THB2 on H4

input group "=== THS (upper band, sell) ==="
input bool     UseTHS              = true;           // Enable
input double   THS_Threshold_Units = 4.0;            // a - x >= this -> Sell, TP = x

input group "=== THB (lower band, buy) ==="
input bool     UseTHB              = true;           // Enable
input double   THB_Threshold_Units = 4.0;            // x2 - a >= this -> Buy, TP = x2

input group "=== THS2 (upper band, sell-limit fade) ==="
input bool     UseTHS2                = true;        // Enable
input double   THS2_Threshold_Units   = 4.0;         // bar0.high - x > this -> Sell Limit at bar0.high, TP = x
input bool     THS2_ChaseAfterFill    = true;         // true: TP chases (InpAddonChaseFraction) after fill; false: static TP=x

input group "=== THB2 (lower band, buy-limit fade) ==="
input bool     UseTHB2                = true;        // Enable
input double   THB2_Threshold_Units   = 4.0;         // x2 - bar0.low > this -> Buy Limit at bar0.low, TP = x2

input group "=== Per-Timeframe Order Limits ==="
input int      M1_MaxConcurrentOrders  = 4;          // M1 max orders
input int      M5_MaxConcurrentOrders  = 3;          // M5 max orders
input int      M15_MaxConcurrentOrders = 3;          // M15 max orders
input int      M30_MaxConcurrentOrders = 3;          // M30 max orders
input int      H1_MaxConcurrentOrders  = 3;          // H1 max orders
input int      H4_MaxConcurrentOrders  = 1;          // H4 max orders
input int      M1_CooldownBars  = 0;                 // M1 min bars since last order (0 = off)
input int      M5_CooldownBars  = 0;                 // M5 min bars since last order (0 = off)
input int      M15_CooldownBars = 0;                 // M15 min bars since last order (0 = off)
input int      M30_CooldownBars = 0;                 // M30 min bars since last order (0 = off)
input int      H1_CooldownBars  = 0;                 // H1 min bars since last order (0 = off)
input int      H4_CooldownBars  = 0;                 // H4 min bars since last order (0 = off)

input group "=== Trade Management ==="
input double   LotSize         = 0.02;               // Lot size
input int      Slippage        = 500;                // Slippage (points)

input group "=== Daily Profit Stop (all enabled timeframes/magics) ==="
input double   DailyProfitStopPct = 100.0;           // Close all + stop trading when PnL gains this % vs snapshot balance (0 = disabled)
input double   DailyProfitStopUSD = 0.0;             // Close all + stop trading when PnL gains this many $ (0 = disabled). If both set, whichever is hit first wins.
input int      SnapHour            = 0;              // Server-time hour (0-23) to take the daily balance snapshot. 0 = midnight.

//--- Per-timeframe state (index: IDX_M1 / IDX_M5 / IDX_M15 / IDX_M30 / IDX_H1 / IDX_H4)
ENUM_TIMEFRAMES g_tf[TF_COUNT];
int             g_magic[TF_COUNT];
bool            g_enabled[TF_COUNT];
int             g_bb_handle[TF_COUNT];
datetime        g_lastBarTime[TF_COUNT];
datetime        g_lastTradeBarTime[TF_COUNT]; // bar time of the most recent order opened, per timeframe
string          g_tfName[TF_COUNT];
string          g_tradeHours[TF_COUNT]; // "" = trade all day, else "1-3,15-20" style ranges (server hour)
int             g_maxConcurrent[TF_COUNT];
int             g_cooldownBars[TF_COUNT];
bool            g_origEnabled[TF_COUNT];  // per-TF isolate switch for THS/THB
bool            g_addonEnabled[TF_COUNT]; // per-TF isolate switch for THS2/THB2
double          g_tpBlendFrac[TF_COUNT];  // per-TF quadratic TP-blend fraction (0 = fully original behavior)

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
   for(int i = 0; i < TF_COUNT; i++)
      if(magic == g_magic[i]) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf[IDX_M1] = PERIOD_M1;   g_tf[IDX_M5] = PERIOD_M5;   g_tf[IDX_M15] = PERIOD_M15;
   g_tf[IDX_M30] = PERIOD_M30; g_tf[IDX_H1] = PERIOD_H1;   g_tf[IDX_H4] = PERIOD_H4;

   g_magic[IDX_M1] = M1_Magic;   g_magic[IDX_M5] = M5_Magic;   g_magic[IDX_M15] = M15_Magic;
   g_magic[IDX_M30] = M30_Magic; g_magic[IDX_H1] = H1_Magic;   g_magic[IDX_H4] = H4_Magic;

   g_enabled[IDX_M1] = Enable_M1;   g_enabled[IDX_M5] = Enable_M5;   g_enabled[IDX_M15] = Enable_M15;
   g_enabled[IDX_M30] = Enable_M30; g_enabled[IDX_H1] = Enable_H1;   g_enabled[IDX_H4] = Enable_H4;

   g_tfName[IDX_M1] = "M1";   g_tfName[IDX_M5] = "M5";   g_tfName[IDX_M15] = "M15";
   g_tfName[IDX_M30] = "M30"; g_tfName[IDX_H1] = "H1";   g_tfName[IDX_H4] = "H4";

   g_tradeHours[IDX_M1] = M1_TradeHours;   g_tradeHours[IDX_M5] = M5_TradeHours;   g_tradeHours[IDX_M15] = M15_TradeHours;
   g_tradeHours[IDX_M30] = M30_TradeHours; g_tradeHours[IDX_H1] = H1_TradeHours;   g_tradeHours[IDX_H4] = H4_TradeHours;

   g_maxConcurrent[IDX_M1] = M1_MaxConcurrentOrders;   g_maxConcurrent[IDX_M5] = M5_MaxConcurrentOrders;
   g_maxConcurrent[IDX_M15] = M15_MaxConcurrentOrders; g_maxConcurrent[IDX_M30] = M30_MaxConcurrentOrders;
   g_maxConcurrent[IDX_H1] = H1_MaxConcurrentOrders;   g_maxConcurrent[IDX_H4] = H4_MaxConcurrentOrders;

   g_cooldownBars[IDX_M1] = M1_CooldownBars;   g_cooldownBars[IDX_M5] = M5_CooldownBars;
   g_cooldownBars[IDX_M15] = M15_CooldownBars; g_cooldownBars[IDX_M30] = M30_CooldownBars;
   g_cooldownBars[IDX_H1] = H1_CooldownBars;   g_cooldownBars[IDX_H4] = H4_CooldownBars;

   g_origEnabled[IDX_M1] = Orig_M1;   g_origEnabled[IDX_M5] = Orig_M5;
   g_origEnabled[IDX_M15] = Orig_M15; g_origEnabled[IDX_M30] = Orig_M30;
   g_origEnabled[IDX_H1] = Orig_H1;   g_origEnabled[IDX_H4] = Orig_H4;

   g_addonEnabled[IDX_M1] = Addon_M1;   g_addonEnabled[IDX_M5] = Addon_M5;
   g_addonEnabled[IDX_M15] = Addon_M15; g_addonEnabled[IDX_M30] = Addon_M30;
   g_addonEnabled[IDX_H1] = Addon_H1;   g_addonEnabled[IDX_H4] = Addon_H4;

   g_tpBlendFrac[IDX_M1] = M1_TPBlendFrac;   g_tpBlendFrac[IDX_M5] = M5_TPBlendFrac;
   g_tpBlendFrac[IDX_M15] = M15_TPBlendFrac; g_tpBlendFrac[IDX_M30] = M30_TPBlendFrac;
   g_tpBlendFrac[IDX_H1] = H1_TPBlendFrac;   g_tpBlendFrac[IDX_H4] = H4_TPBlendFrac;

   for(int i = 0; i < TF_COUNT; i++)
      for(int j = i + 1; j < TF_COUNT; j++)
         if(g_magic[i] == g_magic[j])
         {
            Print("All 6 timeframe magic numbers (M1/M5/M15/M30/H1/H4) must be different");
            return(INIT_FAILED);
         }

   for(int i = 0; i < TF_COUNT; i++)
   {
      g_bb_handle[i] = INVALID_HANDLE;
      g_lastBarTime[i] = 0;
      g_lastTradeBarTime[i] = 0;

      if(!g_enabled[i])
         continue;

      g_bb_handle[i] = iBands(_Symbol, g_tf[i], BB_Period, 0, BB_Deviation, BB_Price);
      if(g_bb_handle[i] == INVALID_HANDLE)
      {
         Print("Failed to init Bollinger Band for ", g_tfName[i]);
         return(INIT_FAILED);
      }
   }

   if(InpDebugBandSolve)
   {
      g_bandSolveHandle = FileOpen("BB_bandsolve_debug.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
      if(g_bandSolveHandle != INVALID_HANDLE)
         FileWrite(g_bandSolveHandle, "Time", "TF", "Side", "Snapshot", "Solved", "Diff", "UsedFallback",
                   "SigOrigOld", "SigOrigNew", "SigAddonOld", "SigAddonNew");
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
      if(IsOurMagic(PositionGetInteger(POSITION_MAGIC)) && PositionGetString(POSITION_SYMBOL) == _Symbol)
         g_ourOpenCount++;
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Chase + max-bars exit.                                            |
//| TP re-pegs every bar using InpChaseFraction interpolated between  |
//| the PREVIOUS TP (seeded with the entry band value) and the latest |
//| closed bar's price -- an EMA of price with smoothing = frac, so   |
//| the price-to-TP gap tracks per-bar movement, not total distance   |
//| run since entry:                                                  |
//|   sell: TP = lastTp + frac*(newClose - lastTp)                    |
//|   buy:  TP = lastTp - frac*(lastTp - newClose)                    |
//| frac=1 -> TP hugs the current price (closes almost immediately).  |
//| InpMaxBarsHold>0 also force-closes after that many bars (0=never).|
//+------------------------------------------------------------------+
#define MAX_TPCHASE_TRACK 500
ulong  g_tpTicket[MAX_TPCHASE_TRACK];
bool   g_tpIsSell[MAX_TPCHASE_TRACK];
int    g_tpTf[MAX_TPCHASE_TRACK];
int    g_tpBars[MAX_TPCHASE_TRACK];
double g_tpLastTp[MAX_TPCHASE_TRACK];
double g_tpFraction[MAX_TPCHASE_TRACK]; // per-slot: InpChaseFraction (THS/THB) or InpAddonChaseFraction (THS2/THB2)
int    g_tpCount = 0;

void RegisterOneBarExit(int tf, ulong ticket, bool isSell, double seedTp, double fraction)
{
   if(g_tpCount >= MAX_TPCHASE_TRACK) return;
   g_tpTicket[g_tpCount] = ticket;
   g_tpIsSell[g_tpCount] = isSell;
   g_tpTf[g_tpCount] = tf;
   g_tpBars[g_tpCount] = 0;
   g_tpLastTp[g_tpCount] = seedTp;
   g_tpFraction[g_tpCount] = fraction;
   g_tpCount++;
}

void DropTpChaseSlot(int i)
{
   g_tpTicket[i] = g_tpTicket[g_tpCount - 1];
   g_tpIsSell[i] = g_tpIsSell[g_tpCount - 1];
   g_tpTf[i] = g_tpTf[g_tpCount - 1];
   g_tpBars[i] = g_tpBars[g_tpCount - 1];
   g_tpLastTp[i] = g_tpLastTp[g_tpCount - 1];
   g_tpFraction[i] = g_tpFraction[g_tpCount - 1];
   g_tpCount--;
}

void UpdateOneBarExit(int tf)
{
   double newClose = iClose(_Symbol, g_tf[tf], 1); // just-closed bar's close
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double yArr[]; ArraySetAsSeries(yArr, true);
   double y2Arr[]; ArraySetAsSeries(y2Arr, true);
   bool haveY = false, haveY2 = false;
   if(InpUseBandChase)
   {
      haveY = CopyBuffer(g_bb_handle[tf], 1, 1, 1, yArr) > 0;
      haveY2 = CopyBuffer(g_bb_handle[tf], 2, 1, 1, y2Arr) > 0;
   }

   for(int i = g_tpCount - 1; i >= 0; i--)
   {
      if(g_tpTf[i] != tf) continue;

      if(!PositionSelectByTicket(g_tpTicket[i]))
      {
         DropTpChaseSlot(i); // closed already (TP hit or otherwise)
         continue;
      }

      g_tpBars[i]++;
      if(InpMaxBarsHold > 0 && g_tpBars[i] >= InpMaxBarsHold)
      {
         // same retry-on-failure fix as the other two force-close paths --
         // don't abandon tracking if the close itself fails (market closed)
         if(trade.PositionClose(g_tpTicket[i]))
            DropTpChaseSlot(i);
         else
            PrintFormat("[%s] Force-close (%d bars, TP not touched) failed ticket %I64u: %u, will retry next bar", g_tfName[tf], g_tpBars[i], g_tpTicket[i], trade.ResultRetcode());
         continue;
      }

      double newTp;
      if(InpUseBandChase)
      {
         bool ok = g_tpIsSell[i] ? haveY : haveY2;
         if(!ok) continue;
         newTp = NormalizeDouble(g_tpIsSell[i] ? yArr[0] : y2Arr[0], digits);
      }
      else
      {
         double lastTp = g_tpLastTp[i];
         newTp = NormalizeDouble(
            g_tpIsSell[i] ? lastTp + g_tpFraction[i] * (newClose - lastTp)
                          : lastTp - g_tpFraction[i] * (lastTp - newClose),
            digits);
      }
      g_tpLastTp[i] = newTp; // EMA anchor for next bar (unused in band-chase mode), regardless of modify outcome below
      double curTp = PositionGetDouble(POSITION_TP);
      if(MathAbs(curTp - newTp) <= SymbolInfoDouble(_Symbol, SYMBOL_POINT))
         continue;

      // A sell's TP must sit below Bid, a buy's TP must sit above Ask, or the
      // broker rejects the modify outright. If the computed TP already lands
      // on the wrong side (target overshot / price gapped past it) or the
      // modify fails for any other reason (slippage, requote), don't leave a
      // stale TP sitting there forever -- just close at market right now.
      double curPrice = g_tpIsSell[i] ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool tpInvalid = g_tpIsSell[i] ? (newTp >= curPrice) : (newTp <= curPrice);

      bool modifyOk = false;
      if(!tpInvalid)
      {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         request.action = TRADE_ACTION_SLTP;
         request.position = g_tpTicket[i];
         request.symbol = _Symbol;
         request.sl = PositionGetDouble(POSITION_SL);
         request.tp = newTp;
         modifyOk = OrderSend(request, result);
         if(!modifyOk)
            PrintFormat("[%s] TP-chase modify failed ticket %I64u: %d - %s", g_tfName[tf], g_tpTicket[i], result.retcode, result.comment);
      }

      if(!modifyOk)
      {
         // target already reached/overshot, or the modify itself failed -- flatten now.
         // If the close ALSO fails (e.g. market briefly closed), the position is still
         // open -- keep tracking it and retry next bar instead of abandoning the chase.
         if(trade.PositionClose(g_tpTicket[i]))
            DropTpChaseSlot(i);
         else
            PrintFormat("[%s] Force-close (TP invalid or modify failed) failed ticket %I64u: %u, will retry next bar", g_tfName[tf], g_tpTicket[i], trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
//| THS2/THB2 pending-limit tracking. Placed at bar1's open, expires  |
//| (canceled) if still unfilled the NEXT time this runs (= 1 bar     |
//| later). If it filled instead, hand it to the same TP-chase system |
//| as THS/THB when THS2_ChaseAfterFill is on (its TP was already set |
//| to x/x2 at placement, so with chase off it just holds that fixed  |
//| TP forever).                                                      |
//+------------------------------------------------------------------+
#define MAX_PEND_TRACK 200
ulong  g_pendTicket[MAX_PEND_TRACK];
int    g_pendTf[MAX_PEND_TRACK];
bool   g_pendIsSell[MAX_PEND_TRACK];
double g_pendSeedTp[MAX_PEND_TRACK];
int    g_pendCount = 0;

void RegisterPendingLimit(int tf, ulong ticket, bool isSell, double seedTp)
{
   if(g_pendCount >= MAX_PEND_TRACK) return;
   g_pendTicket[g_pendCount] = ticket;
   g_pendTf[g_pendCount] = tf;
   g_pendIsSell[g_pendCount] = isSell;
   g_pendSeedTp[g_pendCount] = seedTp;
   g_pendCount++;
}

void DropPendingSlot(int i)
{
   g_pendTicket[i] = g_pendTicket[g_pendCount - 1];
   g_pendTf[i] = g_pendTf[g_pendCount - 1];
   g_pendIsSell[i] = g_pendIsSell[g_pendCount - 1];
   g_pendSeedTp[i] = g_pendSeedTp[g_pendCount - 1];
   g_pendCount--;
}

void UpdatePendingLimits(int tf)
{
   for(int i = g_pendCount - 1; i >= 0; i--)
   {
      if(g_pendTf[i] != tf) continue;

      if(OrderSelect(g_pendTicket[i]))
      {
         // still resting after a full bar -> expire it. If the cancel itself
         // fails (e.g. market briefly closed), keep tracking and retry next
         // bar instead of abandoning it (same class of bug fixed earlier for
         // the TP-chase force-close path).
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         request.action = TRADE_ACTION_REMOVE;
         request.order = g_pendTicket[i];
         if(OrderSend(request, result))
            DropPendingSlot(i);
         else
            PrintFormat("[%s] Cancel stale THS2/THB2 limit failed ticket %I64u: %d - %s, will retry next bar", g_tfName[tf], g_pendTicket[i], result.retcode, result.comment);
         continue;
      }

      // order gone: filled into a position, or already canceled
      if(PositionSelectByTicket(g_pendTicket[i]))
      {
         if(THS2_ChaseAfterFill)
            RegisterOneBarExit(tf, g_pendTicket[i], g_pendIsSell[i], g_pendSeedTp[i], InpAddonChaseFraction);
         // else: fixed TP=x/x2 already set at placement, nothing more to do
      }
      DropPendingSlot(i);
   }
}

//+------------------------------------------------------------------+
//| ONE-OFF DEBUG (InpDebugNext2): for every order this EA opens,     |
//| log the next 2 closed candles' H/L/C on that TF vs our TP, so we  |
//| can see whether price ever retraced toward TP right after entry. |
//+------------------------------------------------------------------+
#define MAX_DBG_TRACK 3000
int      g_dbgTf[MAX_DBG_TRACK];
datetime g_dbgEntryTime[MAX_DBG_TRACK];
double   g_dbgEntryPrice[MAX_DBG_TRACK];
double   g_dbgTp[MAX_DBG_TRACK];
bool     g_dbgIsSell[MAX_DBG_TRACK];
int      g_dbgBarsLogged[MAX_DBG_TRACK];
datetime g_dbgT1[MAX_DBG_TRACK]; double g_dbgH1[MAX_DBG_TRACK]; double g_dbgL1[MAX_DBG_TRACK]; double g_dbgC1[MAX_DBG_TRACK];
int      g_dbgCount = 0;

void DbgTrackOrder(int tf, bool isSell, double entryPrice, double tp)
{
   if(!InpDebugNext2 || g_dbgCount >= MAX_DBG_TRACK) return;
   g_dbgTf[g_dbgCount] = tf;
   g_dbgEntryTime[g_dbgCount] = iTime(_Symbol, g_tf[tf], 0);
   g_dbgEntryPrice[g_dbgCount] = entryPrice;
   g_dbgTp[g_dbgCount] = tp;
   g_dbgIsSell[g_dbgCount] = isSell;
   g_dbgBarsLogged[g_dbgCount] = 0;
   g_dbgCount++;
}

void DbgOnNewBar(int tf)
{
   if(!InpDebugNext2) return;
   datetime t = iTime(_Symbol, g_tf[tf], 1);
   double h = iHigh(_Symbol, g_tf[tf], 1);
   double l = iLow(_Symbol, g_tf[tf], 1);
   double c = iClose(_Symbol, g_tf[tf], 1);

   for(int i = 0; i < g_dbgCount; i++)
   {
      if(g_dbgTf[i] != tf) continue;
      if(g_dbgBarsLogged[i] == 2) continue;
      if(t <= g_dbgEntryTime[i]) continue; // this closed bar is the entry bar itself, wait for the next one

      if(g_dbgBarsLogged[i] == 0)
      {
         g_dbgT1[i] = t; g_dbgH1[i] = h; g_dbgL1[i] = l; g_dbgC1[i] = c;
         g_dbgBarsLogged[i] = 1;
         continue;
      }

      // second bar -> write the row now
      double bestExtreme = g_dbgIsSell[i] ? MathMin(g_dbgL1[i], l) : MathMax(g_dbgH1[i], h);
      bool wouldHit = g_dbgIsSell[i] ? (bestExtreme <= g_dbgTp[i]) : (bestExtreme >= g_dbgTp[i]);

      int handle = FileOpen("BB_next2_debug.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
      if(handle != INVALID_HANDLE)
      {
         if(FileSize(handle) == 0)
            FileWrite(handle, "TF", "Side", "EntryTime", "EntryPrice", "TP",
                      "Bar1Time", "Bar1High", "Bar1Low", "Bar1Close",
                      "Bar2Time", "Bar2High", "Bar2Low", "Bar2Close", "TP_WouldHaveHit");
         FileSeek(handle, 0, SEEK_END);
         FileWrite(handle, g_tfName[tf], g_dbgIsSell[i] ? "SELL" : "BUY",
                   TimeToString(g_dbgEntryTime[i], TIME_DATE|TIME_SECONDS), g_dbgEntryPrice[i], g_dbgTp[i],
                   TimeToString(g_dbgT1[i], TIME_DATE|TIME_SECONDS), g_dbgH1[i], g_dbgL1[i], g_dbgC1[i],
                   TimeToString(t, TIME_DATE|TIME_SECONDS), h, l, c,
                   wouldHit ? "YES" : "NO");
         FileClose(handle);
      }
      g_dbgBarsLogged[i] = 2;
   }
}

//+------------------------------------------------------------------+
//| close every open position belonging to this EA (any of the 6      |
//| timeframe magics)                                                  |
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
            PrintFormat("BB_H4_EA: profit-stop close of #%I64u failed, retcode %u", ticket, code);
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| cancel every still-pending order belonging to this EA (safety net |
//| in case a manual pending exists - this EA itself never places one) |
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

      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      request.action = TRADE_ACTION_REMOVE;
      request.order = ticket;
      if(!OrderSend(request, result))
         PrintFormat("BB_H4_EA: profit-stop cancel of pending #%I64u failed, retcode %u", ticket, result.retcode);
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

   int h = FileOpen("BB_H4_Balance.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
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
      PrintFormat("BB_H4_EA: %02d:00 balance snapshot %.2f", SnapHour, g_snapshotBalance);
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
         PrintFormat("BB_H4_EA: this EA's PnL since snapshot +%.2f reached the %s threshold (+%.2f). "
                     "Closing all positions/pendings; no new trades until next 00:00 snapshot.",
                     ourPnLToday, hitBy, threshold);
         LogProgress("profit_stop_before_close");
         CloseAllOurs();
         CancelAllOurPendings();
         LogProgress("profit_stop_after_close");
      }
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < TF_COUNT; i++)
      if(g_bb_handle[i] != INVALID_HANDLE)
         IndicatorRelease(g_bb_handle[i]);

   if(g_bandSolveHandle != INVALID_HANDLE)
      FileClose(g_bandSolveHandle);
}

//+------------------------------------------------------------------+
//| Check if a new bar has formed on timeframe slot tf                |
//+------------------------------------------------------------------+
bool IsNewBar(int tf)
{
   datetime currentBarTime = iTime(_Symbol, g_tf[tf], 0);
   if(currentBarTime != g_lastBarTime[tf])
   {
      g_lastBarTime[tf] = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| "" = allowed all day. Else comma-separated "start-end" hour       |
//| ranges (server time, inclusive), e.g. "1-3,15-20". A range where  |
//| start>end wraps midnight (e.g. "22-2").                          |
//+------------------------------------------------------------------+
bool IsTradeHourAllowed(string ranges, int hour)
{
   if(ranges == "") return true;

   string parts[];
   int n = StringSplit(ranges, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string token = parts[i];
      StringTrimLeft(token);
      StringTrimRight(token);
      if(token == "") continue;

      string bounds[];
      if(StringSplit(token, '-', bounds) != 2) continue;
      int start = (int)StringToInteger(bounds[0]);
      int end   = (int)StringToInteger(bounds[1]);

      bool inRange = (start <= end) ? (hour >= start && hour <= end)
                                     : (hour >= start || hour <= end);
      if(inRange) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Count open positions with the given magic                        |
//+------------------------------------------------------------------+
int CountOpenPositions(int magic)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magic)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count pending orders with the given magic                        |
//+------------------------------------------------------------------+
int CountPendingOrders(int magic)
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
            OrderGetInteger(ORDER_MAGIC) == magic)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Open+pending positions across ALL 6 timeframes combined (any of  |
//| our magics). Used for InpGlobalMaxConcurrent -- caps correlated   |
//| exposure when multiple TFs fire on the same underlying move.      |
//+------------------------------------------------------------------+
int CountAllOurOpenAndPending()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         count++;
   }
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && IsOurMagic(OrderGetInteger(ORDER_MAGIC)))
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Open market order with absolute TP price. SL = InpHardSLUnits     |
//| price units from entry (0 = no SL), fixed for the trade's life -- |
//| TP keeps chasing on top of it. Returns the position ticket        |
//| (== order ticket for a market fill), 0 on failure.                |
//+------------------------------------------------------------------+
ulong OpenOrder(ENUM_ORDER_TYPE orderType, double tpPrice, string comment, int tf)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   string fullComment = g_tfName[tf] + "_" + comment; // e.g. "H4_THS", "M1_THB"

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double entryPrice = (orderType == ORDER_TYPE_BUY)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = 0;
   if(InpHardSLUnits > 0)
   {
      double slDist = InpHardSLUnits * PriceUnit;
      sl = NormalizeDouble(orderType == ORDER_TYPE_BUY ? entryPrice - slDist : entryPrice + slDist, digits);
   }

   request.action       = TRADE_ACTION_DEAL;
   request.symbol        = _Symbol;
   request.volume        = LotSize;
   request.type          = orderType;
   request.price         = entryPrice;
   request.sl            = sl;
   request.tp            = NormalizeDouble(tpPrice, digits);
   request.deviation     = Slippage;
   request.magic         = g_magic[tf];
   request.comment       = fullComment;
   request.type_filling  = ORDER_FILLING_FOK;

   if(!OrderSend(request, result))
   {
      Print("Order failed ", fullComment, ": ", result.retcode, " - ", result.comment);
      return 0;
   }

   Print("Order opened ", fullComment, ", ticket: ", result.order, ", entry: ", entryPrice, ", TP: ", tpPrice);
   g_lastTradeBarTime[tf] = iTime(_Symbol, g_tf[tf], 0);
   DbgTrackOrder(tf, orderType == ORDER_TYPE_SELL, entryPrice, tpPrice);
   return result.order;
}

//+------------------------------------------------------------------+
//| Place a resting Sell/Buy Limit (THS2/THB2). SL = InpHardSLUnits   |
//| same as OpenOrder. Returns the pending order ticket, 0 on failure.|
//+------------------------------------------------------------------+
ulong OpenLimitOrder(bool isSell, double limitPrice, double tpPrice, string comment, int tf)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   string fullComment = g_tfName[tf] + "_" + comment; // e.g. "H4_THS2", "M1_THB2"
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = 0;
   if(InpHardSLUnits > 0)
   {
      double slDist = InpHardSLUnits * PriceUnit;
      sl = NormalizeDouble(isSell ? limitPrice + slDist : limitPrice - slDist, digits);
   }

   request.action       = TRADE_ACTION_PENDING;
   request.symbol        = _Symbol;
   request.volume        = LotSize;
   request.type          = isSell ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;
   request.price         = NormalizeDouble(limitPrice, digits);
   request.sl            = sl;
   request.tp            = NormalizeDouble(tpPrice, digits);
   request.magic         = g_magic[tf];
   request.comment       = fullComment;
   request.type_time     = ORDER_TIME_GTC;

   if(!OrderSend(request, result))
   {
      Print("Limit order failed ", fullComment, ": ", result.retcode, " - ", result.comment);
      return 0;
   }

   Print("Limit order placed ", fullComment, ", ticket: ", result.order, ", price: ", limitPrice, ", TP: ", tpPrice);
   return result.order;
}

//+------------------------------------------------------------------+
//| Applied price of one bar, per BB_Price -- mirrors what iBands     |
//| itself feeds into SMA/stddev for that bar.                        |
//+------------------------------------------------------------------+
double AppliedPrice(int tf, int shift)
{
   switch(BB_Price)
   {
      case PRICE_OPEN:     return iOpen(_Symbol, g_tf[tf], shift);
      case PRICE_HIGH:     return iHigh(_Symbol, g_tf[tf], shift);
      case PRICE_LOW:      return iLow(_Symbol, g_tf[tf], shift);
      case PRICE_MEDIAN:   return (iHigh(_Symbol, g_tf[tf], shift) + iLow(_Symbol, g_tf[tf], shift)) / 2.0;
      case PRICE_TYPICAL:  return (iHigh(_Symbol, g_tf[tf], shift) + iLow(_Symbol, g_tf[tf], shift) + iClose(_Symbol, g_tf[tf], shift)) / 3.0;
      case PRICE_WEIGHTED: return (iHigh(_Symbol, g_tf[tf], shift) + iLow(_Symbol, g_tf[tf], shift) + 2.0 * iClose(_Symbol, g_tf[tf], shift)) / 4.0;
      default:             return iClose(_Symbol, g_tf[tf], shift); // PRICE_CLOSE
   }
}

//+------------------------------------------------------------------+
//| Self-consistent band point: solves Band(P) = P (quadratic in P,   |
//| mean linear + var quadratic). S/Q are the BB_Period-1 already-    |
//| CLOSED bars (shift 1..BB_Period-1); fallback = shift-0 snapshot,  |
//| used only if no valid root on the correct side exists.            |
//+------------------------------------------------------------------+
double SolveBandPoint(int tf, bool upper, double fallback, bool &usedFallback)
{
   usedFallback = false;
   int    N = BB_Period;
   double k = BB_Deviation;
   double S = 0.0, Q = 0.0;
   for(int i = 1; i < N; i++)
   {
      double p = AppliedPrice(tf, i);
      S += p;
      Q += p * p;
   }

   double m = (double)(N - 1) - k * k;
   double A = (N - 1) * m;
   double B = -2.0 * S * m;
   double C = S * S * (1.0 + k * k) - k * k * N * Q;

   if(MathAbs(A) < 1e-8) { usedFallback = true; return fallback; }
   double disc = B * B - 4.0 * A * C;
   if(disc < 0) { usedFallback = true; return fallback; }

   double sq = MathSqrt(disc);
   double r1 = (-B + sq) / (2.0 * A);
   double r2 = (-B - sq) / (2.0 * A);
   double d1 = r1 - (S + r1) / N;
   double d2 = r2 - (S + r2) / N;

   if(upper)
   {
      if(d1 >= 0 && d2 < 0) return r1;
      if(d2 >= 0 && d1 < 0) return r2;
      if(d1 >= 0 && d2 >= 0) return MathMax(r1, r2);
   }
   else
   {
      if(d1 <= 0 && d2 > 0) return r1;
      if(d2 <= 0 && d1 > 0) return r2;
      if(d1 <= 0 && d2 <= 0) return MathMin(r1, r2);
   }
   usedFallback = true;
   return fallback;
}

//+------------------------------------------------------------------+
//| InpDebugBandSolve: one row per new bar per side, comparing the    |
//| shift-0 snapshot against the solved point -- to check which way   |
//| (and how far) the solve moves the band vs the old approximation.  |
//+------------------------------------------------------------------+
int g_bandSolveHandle = INVALID_HANDLE; // opened once in OnInit, kept open -- per-call FileOpen/FileClose was the earlier perf bug

void LogBandSolve(int tf, string side, double snapshot, double solved, bool usedFallback,
                  bool sigAOld, bool sigANew, bool sigBOld, bool sigBNew)
{
   if(!InpDebugBandSolve || g_bandSolveHandle == INVALID_HANDLE) return;
   FileWrite(g_bandSolveHandle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), g_tfName[tf], side,
             snapshot, solved, solved - snapshot, usedFallback ? "YES" : "NO",
             sigAOld ? "YES" : "NO", sigANew ? "YES" : "NO", sigBOld ? "YES" : "NO", sigBNew ? "YES" : "NO");
}

//+------------------------------------------------------------------+
//| THS (upper band, sell): bid - x >= THS_Threshold_Units -> Sell    |
//| instant, TP = x. Checked against Bid (the real sell fill price),  |
//| not the stale bar close, so spread can't eat the TP margin.       |
//+------------------------------------------------------------------+
void CheckAndTrade_UpperBand(int tf)
{
   if((!InpUseOriginalEA || !UseTHS || !g_origEnabled[tf]) && (!InpUseAddonEA || !UseTHS2 || !g_addonEnabled[tf])) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID); // real sell fill price

   // x = upper band RIGHT WHEN the new bar opened (shift 0, read now) -- also THS2's TP
   double xArr[];
   ArraySetAsSeries(xArr, true);
   if(CopyBuffer(g_bb_handle[tf], 1, 0, 1, xArr) <= 0)
   {
      Print("[", g_tfName[tf], "] Failed to read x (band shift0)");
      return;
   }
   bool xUsedFallback = false;
   double xEntry = xArr[0], xTP = xArr[0]; // per-TF frac==0 (default for every TF except M1): fully original snapshot behavior
   if(g_tpBlendFrac[tf] > 0)
   {
      xEntry = SolveBandPoint(tf, true, xArr[0], xUsedFallback); // threshold uses quadratic (easier entry, per debug findings)
      xTP = xArr[0] + g_tpBlendFrac[tf] * (xEntry - xArr[0]);    // TP blended baseline<->quadratic
   }

   if(InpDebugBandSolve)
   {
      double dbgBar0High = iHigh(_Symbol, g_tf[tf], 1);
      double dbgBar0Close = iClose(_Symbol, g_tf[tf], 1);
      bool thsOld = bid - xArr[0] >= THS_Threshold_Units * PriceUnit;
      bool thsNew = bid - xEntry >= THS_Threshold_Units * PriceUnit;
      bool ths2Old = dbgBar0High - xArr[0] > THS2_Threshold_Units * PriceUnit && dbgBar0Close - xArr[0] >= THS2_Threshold_Units * PriceUnit;
      bool ths2New = dbgBar0High - xEntry > THS2_Threshold_Units * PriceUnit && dbgBar0Close - xEntry >= THS2_Threshold_Units * PriceUnit;
      LogBandSolve(tf, "UPPER", xArr[0], xEntry, xUsedFallback, thsOld, thsNew, ths2Old, ths2New);
   }

   if(InpUseOriginalEA && UseTHS && g_origEnabled[tf] && bid - xEntry >= THS_Threshold_Units * PriceUnit)
   {
      ulong ticket = OpenOrder(ORDER_TYPE_SELL, xTP, "THS", tf);
      if(ticket != 0)
         RegisterOneBarExit(tf, ticket, true, xTP, InpChaseFraction);
   }

   if(InpUseAddonEA && UseTHS2 && g_addonEnabled[tf])
   {
      double bar0High = iHigh(_Symbol, g_tf[tf], 1); // bar0 = just-closed bar
      double bar0Close = iClose(_Symbol, g_tf[tf], 1);
      // require the wick (high) AND the settled close both clear the threshold --
      // filters out bars that only spiked on a wick and closed back near the band
      if(bar0High - xEntry > THS2_Threshold_Units * PriceUnit && bar0Close - xEntry >= THS2_Threshold_Units * PriceUnit)
      {
         ulong ticket = OpenLimitOrder(true, bar0High, xTP, "THS2", tf);
         if(ticket != 0)
            RegisterPendingLimit(tf, ticket, true, xTP);
      }
   }
}

//+------------------------------------------------------------------+
//| THB (lower band, buy): x2 - ask >= THB_Threshold_Units -> Buy     |
//| instant, TP = x2. Checked against Ask (the real buy fill price),  |
//| not the stale bar close, so spread can't eat the TP margin.       |
//+------------------------------------------------------------------+
void CheckAndTrade_LowerBand(int tf)
{
   if((!InpUseOriginalEA || !UseTHB || !g_origEnabled[tf]) && (!InpUseAddonEA || !UseTHB2 || !g_addonEnabled[tf])) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // real buy fill price

   // x2 = lower band RIGHT WHEN the new bar opened (shift 0) -- buffer index 2 = lower band, also THB2's TP
   double x2Arr[];
   ArraySetAsSeries(x2Arr, true);
   if(CopyBuffer(g_bb_handle[tf], 2, 0, 1, x2Arr) <= 0)
   {
      Print("[", g_tfName[tf], "] Failed to read x2 (lower band shift0)");
      return;
   }
   bool x2UsedFallback = false;
   double x2Entry = x2Arr[0], x2TP = x2Arr[0]; // per-TF frac==0 (default for every TF except M1): fully original snapshot behavior
   if(g_tpBlendFrac[tf] > 0)
   {
      x2Entry = SolveBandPoint(tf, false, x2Arr[0], x2UsedFallback); // threshold uses quadratic
      x2TP = x2Arr[0] + g_tpBlendFrac[tf] * (x2Entry - x2Arr[0]);    // TP blended baseline<->quadratic
   }

   if(InpDebugBandSolve)
   {
      double dbgBar0Low = iLow(_Symbol, g_tf[tf], 1);
      double dbgBar0Close = iClose(_Symbol, g_tf[tf], 1);
      bool thbOld = x2Arr[0] - ask >= THB_Threshold_Units * PriceUnit;
      bool thbNew = x2Entry - ask >= THB_Threshold_Units * PriceUnit;
      bool thb2Old = x2Arr[0] - dbgBar0Low > THB2_Threshold_Units * PriceUnit && x2Arr[0] - dbgBar0Close >= THB2_Threshold_Units * PriceUnit;
      bool thb2New = x2Entry - dbgBar0Low > THB2_Threshold_Units * PriceUnit && x2Entry - dbgBar0Close >= THB2_Threshold_Units * PriceUnit;
      LogBandSolve(tf, "LOWER", x2Arr[0], x2Entry, x2UsedFallback, thbOld, thbNew, thb2Old, thb2New);
   }

   if(InpUseOriginalEA && UseTHB && g_origEnabled[tf] && x2Entry - ask >= THB_Threshold_Units * PriceUnit)
   {
      ulong ticket = OpenOrder(ORDER_TYPE_BUY, x2TP, "THB", tf);
      if(ticket != 0)
         RegisterOneBarExit(tf, ticket, false, x2TP, InpChaseFraction);
   }

   if(InpUseAddonEA && UseTHB2 && g_addonEnabled[tf])
   {
      double bar0Low = iLow(_Symbol, g_tf[tf], 1); // bar0 = just-closed bar
      double bar0Close = iClose(_Symbol, g_tf[tf], 1);
      // require the wick (low) AND the settled close both clear the threshold --
      // filters out bars that only spiked on a wick and closed back near the band
      if(x2Entry - bar0Low > THB2_Threshold_Units * PriceUnit && x2Entry - bar0Close >= THB2_Threshold_Units * PriceUnit)
      {
         ulong ticket = OpenLimitOrder(false, bar0Low, x2TP, "THB2", tf);
         if(ticket != 0)
            RegisterPendingLimit(tf, ticket, false, x2TP);
      }
   }
}

//+------------------------------------------------------------------+
//| Check upper band, then lower band - both independent, each only  |
//| gated by this timeframe's own max-concurrent-orders cap.         |
//+------------------------------------------------------------------+
void CheckAndTrade(int tf)
{
   if(g_profitStopHit)
      return; // daily profit-stop tripped -- no new entries until next 00:00 snapshot

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(!IsTradeHourAllowed(g_tradeHours[tf], now.hour))
      return; // outside allowed trading hours for this timeframe

   int cooldown = g_cooldownBars[tf];
   if(cooldown > 0 && g_lastTradeBarTime[tf] != 0)
   {
      int barsSinceLastTrade = iBarShift(_Symbol, g_tf[tf], g_lastTradeBarTime[tf], false);
      if(barsSinceLastTrade <= cooldown)
         return; // too soon since last order on this timeframe - skip both bands this bar
   }

   if(InpGlobalMaxConcurrent > 0 && CountAllOurOpenAndPending() >= InpGlobalMaxConcurrent)
      return; // cross-TF cap hit -- caps correlated exposure when several TFs fire on the same move

   int cap = g_maxConcurrent[tf];
   int magic = g_magic[tf];

   if(CountOpenPositions(magic) + CountPendingOrders(magic) < cap)
      CheckAndTrade_UpperBand(tf);

   if(CountOpenPositions(magic) + CountPendingOrders(magic) < cap)
      CheckAndTrade_LowerBand(tf);
}

//+------------------------------------------------------------------+
//| Expert tick function - loop over enabled timeframe slots         |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateProfitStop();

   for(int tf = 0; tf < TF_COUNT; tf++)
   {
      if(!g_enabled[tf])
         continue;

      // Only check signals on a new bar of this timeframe
      if(!IsNewBar(tf))
         continue;

      UpdateOneBarExit(tf); // force-close any position still open one bar after entry
      UpdatePendingLimits(tf); // cancel stale THS2/THB2 limits, hand filled ones to the chase system
      DbgOnNewBar(tf); // one-off debug: log next-2-candle data for tracked orders

      // Upper and lower band checked independently, each gated only by
      // this timeframe's own concurrent-orders cap (see CheckAndTrade)
      CheckAndTrade(tf);
   }
}

//+------------------------------------------------------------------+
//| Tester-only: dump full deal history as CSV to Common\Files so a   |
//| headless run can be parsed without touching the huge .htm report. |
//| No-op unless InpCsvDumpName is set (leave blank for live trading).|
//+------------------------------------------------------------------+
double OnTester()
{
   if(InpCsvDumpName == "") return(0.0);
   if(!HistorySelect(0, TimeCurrent())) return(0.0);

   string fname = InpCsvDumpName + "_m1frac" + DoubleToString(M1_TPBlendFrac, 2) + ".csv"; // encode swept input so grid passes never collide
   int handle = FileOpen(fname, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE) return(0.0);

   FileWrite(handle, "Time", "Deal", "Symbol", "Type", "Direction", "Volume", "Price", "Order", "Position", "Magic", "Commission", "Swap", "Profit", "Balance", "Comment");

   int total = HistoryDealsTotal();
   double runningBalance = 0.0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      runningBalance += profit + swap + commission;

      FileWrite(handle,
                TimeToString((datetime)HistoryDealGetInteger(ticket, DEAL_TIME), TIME_DATE | TIME_SECONDS),
                (long)ticket,
                HistoryDealGetString(ticket, DEAL_SYMBOL),
                EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE)),
                EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY)),
                HistoryDealGetDouble(ticket, DEAL_VOLUME),
                HistoryDealGetDouble(ticket, DEAL_PRICE),
                (long)HistoryDealGetInteger(ticket, DEAL_ORDER),
                (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID),
                (long)HistoryDealGetInteger(ticket, DEAL_MAGIC),
                commission,
                swap,
                profit,
                runningBalance,
                HistoryDealGetString(ticket, DEAL_COMMENT));
   }

   FileClose(handle);
   return(0.0);
}
//+------------------------------------------------------------------+
