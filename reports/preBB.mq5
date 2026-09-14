//+------------------------------------------------------------------+
//|                                                  BB_H4_EA.mq5    |
//|  EA: Bollinger-band breakout, 4 timeframes (M5/M15/M30/H1), one   |
//|  signal family, TP that re-pegs every bar (EMA-smoothed toward    |
//|  the latest close) instead of a fixed target -- and no SL.        |
//|                                                                    |
//|  Signal (symmetric, checked the instant a new bar opens):         |
//|   thr = K_Threshold_Pct % of the band price (scales with gold)     |
//|   SELL: bar0.high - x  > thr -> Sell instant, TP=x                 |
//|   BUY:  x2 - bar0.low  > thr -> Buy instant,  TP=x2                |
//|  where bar0 = just-closed bar, x/x2 = upper/lower band value read |
//|  live at shift0 the instant the new bar opens.                   |
//|                                                                    |
//|  TP chase: every bar, TP moves toward the latest close by a       |
//|  per-timeframe fraction (Mx_ChaseFraction) -- an EMA of price, so  |
//|  the price-to-TP gap tracks per-bar movement instead of growing    |
//|  with total distance since entry. If the chase can't legally move |
//|  TP (wrong side of price) or the modify/close itself fails, the   |
//|  position is force-closed at market (or, if that also fails e.g.  |
//|  market briefly closed, tracking is kept and retried next bar     |
//|  rather than abandoned).                                          |
//|                                                                    |
//|  ONE EA instance runs all 4 timeframes together: M5 M15 M30 H1,   |
//|  each with its own MagicNumber (must be unique) so                |
//|  positions/orders never mix between them.                         |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "6.00"
#property strict
#include <Trade\Trade.mqh>

CTrade trade; // used only for CloseAllOurs()/pending cancel; order opening below still uses raw OrderSend

//--- Timeframe slot indices
#define IDX_M5  0
#define IDX_M15 1
#define IDX_M30 2
#define IDX_H1  3
#define TF_COUNT 4

//--- Input parameters
input group "=== Tester CSV dump ==="
input string   InpCsvDumpName = "";                 // if set, OnTester writes deals to <name>.csv (Common\Files)
input bool     InpDebugNext2  = false;              // one-off: dump next-2-candle H/C vs TP for the 10 known losers
input bool     InpDebugTpChase = false;             // if true (and InpCsvDumpName set): log every TP-chase update to <name>_tpchase.csv
input int      InpMaxBarsHold = 0;                  // force-close if TP not touched after this many bars (0 = chase forever)
input double   InpHardSLUnits = 0;                  // fixed SL distance from entry, price units (0 = no SL)
input bool     InpUseBandChase = false;             // true: TP chases the live band value (y/y2) each bar instead of the EMA-fraction formula
input int      InpGlobalMaxConcurrent = 0;          // cap on open+pending positions across ALL 4 timeframes combined (0 = no cap, per-TF caps still apply)

input group "=== Timeframes ==="
input bool     Enable_M5   = true;                  // Run M5
input bool     Enable_M15  = true;                  // Run M15
input bool     Enable_M30  = true;                  // Run M30
input bool     Enable_H1   = true;                  // Run H1
input int      M5_Magic    = 111005;                // M5 magic (unique)
input int      M15_Magic   = 111015;                // M15 magic (unique)
input int      M30_Magic   = 111030;                // M30 magic (unique)
input int      H1_Magic    = 111060;                // H1 magic (unique)

input group "=== Trading Hours (server time, empty = all day) ==="
input string   M5_TradeHours  = "";                 // M5 hours e.g. "1-3,15-20"
input string   M15_TradeHours = "";                 // M15 hours e.g. "1-3,15-20"
input string   M30_TradeHours = "";                 // M30 hours e.g. "1-3,15-20"
input string   H1_TradeHours  = "";                 // H1 hours e.g. "1-3,15-20"

input group "=== Bollinger Band ==="
input int      BB_Period       = 20;                // Period
input double   BB_Deviation    = 2.0;                // Deviation
input ENUM_APPLIED_PRICE BB_Price = PRICE_CLOSE;     // Applied price

input group "=== Price Unit ==="
input double   PriceUnit       = 1.0;                // 1 unit = X price points

input group "=== Signal ==="
input double   K_Threshold_Pct = 0.55;              // thr = Pct% of band price; bar0.high-x>thr -> Sell TP=x / x2-bar0.low>thr -> Buy TP=x2 (all 4 TF)
input double   K_Threshold_Dollar = 0.0;            // if >0, use this fixed $ threshold instead of Pct (for $-scale re-sweeps)

input group "=== TP chase fraction (per-TF) ==="
input double   M5_ChaseFraction  = 0.6;             // TP = lastTp + frac*(newClose-lastTp) [sell] / lastTp - frac*(lastTp-newClose) [buy]
input double   M15_ChaseFraction = 0.5;
input double   M30_ChaseFraction = 0.75;
input double   H1_ChaseFraction  = 0.5;

input group "=== Optimizer helpers (leave -1 for normal use) ==="
input int      Opt_TfSelect = -1;                    // -1: use Enable_* ; 0=M5 1=M15 2=M30 3=H1 only ; 4=all four
input int      Opt_FracIdx  = -1;                    // -1: use Mx_ChaseFraction ; 0=0.5 1=0.6 2=2/3 3=0.75 for all TF
input bool     Opt_BandShift1 = false;               // repaint check: true = read band value at shift1 (closed bar) instead of shift0 (forming bar)

input group "=== Per-Timeframe Order Limits ==="
input int      M5_MaxConcurrentOrders  = 3;          // M5 max orders
input int      M15_MaxConcurrentOrders = 3;          // M15 max orders
input int      M30_MaxConcurrentOrders = 3;          // M30 max orders
input int      H1_MaxConcurrentOrders  = 3;          // H1 max orders
input int      M5_CooldownBars  = 0;                 // M5 min bars since last order (0 = off)
input int      M15_CooldownBars = 0;                 // M15 min bars since last order (0 = off)
input int      M30_CooldownBars = 0;                 // M30 min bars since last order (0 = off)
input int      H1_CooldownBars  = 0;                 // H1 min bars since last order (0 = off)

input group "=== Trade Management ==="
input double   LotSize         = 0.01;               // Lot size
input int      Slippage        = 10;                 // Slippage (points)

input group "=== Daily Profit Stop (all enabled timeframes/magics) ==="
input double   DailyProfitStopPct = 0.0;             // Close all + stop trading when PnL gains this % vs snapshot balance (0 = disabled)
input double   DailyProfitStopUSD = 0.0;             // Close all + stop trading when PnL gains this many $ (0 = disabled). If both set, whichever is hit first wins.
input int      SnapHour            = 0;              // Server-time hour (0-23) to take the daily balance snapshot. 0 = midnight.

//--- Per-timeframe state (index: IDX_M5 / IDX_M15 / IDX_M30 / IDX_H1)
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
double          g_chaseFraction[TF_COUNT]; // per-TF TP-chase fraction

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
   g_tf[IDX_M5] = PERIOD_M5;   g_tf[IDX_M15] = PERIOD_M15;
   g_tf[IDX_M30] = PERIOD_M30; g_tf[IDX_H1] = PERIOD_H1;

   g_magic[IDX_M5] = M5_Magic;   g_magic[IDX_M15] = M15_Magic;
   g_magic[IDX_M30] = M30_Magic; g_magic[IDX_H1] = H1_Magic;

   g_enabled[IDX_M5] = Enable_M5;   g_enabled[IDX_M15] = Enable_M15;
   g_enabled[IDX_M30] = Enable_M30; g_enabled[IDX_H1] = Enable_H1;
   if(Opt_TfSelect >= 0 && Opt_TfSelect <= 4)
      for(int k = 0; k < TF_COUNT; k++) g_enabled[k] = (Opt_TfSelect == 4 || k == Opt_TfSelect);

   g_tfName[IDX_M5] = "M5";   g_tfName[IDX_M15] = "M15";
   g_tfName[IDX_M30] = "M30"; g_tfName[IDX_H1] = "H1";

   g_tradeHours[IDX_M5] = M5_TradeHours;   g_tradeHours[IDX_M15] = M15_TradeHours;
   g_tradeHours[IDX_M30] = M30_TradeHours; g_tradeHours[IDX_H1] = H1_TradeHours;

   g_maxConcurrent[IDX_M5] = M5_MaxConcurrentOrders;   g_maxConcurrent[IDX_M15] = M15_MaxConcurrentOrders;
   g_maxConcurrent[IDX_M30] = M30_MaxConcurrentOrders; g_maxConcurrent[IDX_H1] = H1_MaxConcurrentOrders;

   g_cooldownBars[IDX_M5] = M5_CooldownBars;   g_cooldownBars[IDX_M15] = M15_CooldownBars;
   g_cooldownBars[IDX_M30] = M30_CooldownBars; g_cooldownBars[IDX_H1] = H1_CooldownBars;

   g_chaseFraction[IDX_M5] = M5_ChaseFraction;   g_chaseFraction[IDX_M15] = M15_ChaseFraction;
   g_chaseFraction[IDX_M30] = M30_ChaseFraction; g_chaseFraction[IDX_H1] = H1_ChaseFraction;
   if(Opt_FracIdx >= 0 && Opt_FracIdx <= 3)
   {
      double fr[4] = {0.5, 0.6, 2.0 / 3.0, 0.75};
      for(int k = 0; k < TF_COUNT; k++) g_chaseFraction[k] = fr[Opt_FracIdx];
   }

   for(int i = 0; i < TF_COUNT; i++)
      for(int j = i + 1; j < TF_COUNT; j++)
         if(g_magic[i] == g_magic[j])
         {
            Print("All 4 timeframe magic numbers (M5/M15/M30/H1) must be different");
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
//| TP re-pegs every bar using this TF's chase fraction interpolated  |
//| between the PREVIOUS TP (seeded with the entry band value) and    |
//| the latest closed bar's price -- an EMA of price, so the          |
//| price-to-TP gap tracks per-bar movement, not total distance run   |
//| since entry:                                                      |
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
double g_tpFraction[MAX_TPCHASE_TRACK]; // per-slot: this TF's chase fraction
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
      double oldTp = g_tpLastTp[i];
      g_tpLastTp[i] = newTp; // EMA anchor for next bar (unused in band-chase mode), regardless of modify outcome below

      if(InpCsvDumpName != "" && InpDebugTpChase)
      {
         int th = FileOpen(InpCsvDumpName + "_tpchase.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
         if(th != INVALID_HANDLE)
         {
            FileSeek(th, 0, SEEK_END);
            FileWrite(th, g_tpTicket[i], TimeToString(iTime(_Symbol, g_tf[tf], 1), TIME_DATE|TIME_MINUTES),
                      g_tfName[tf], g_tpBars[i], newClose, oldTp, newTp);
            FileClose(th);
         }
      }

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
//| close every open position belonging to this EA (any of the 4      |
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
//| Open+pending positions across ALL 4 timeframes combined (any of  |
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

   string fullComment = g_tfName[tf] + "_" + comment; // e.g. "H1_SELL", "M5_BUY"

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
//| SELL: bar0.high - x > K_Threshold_Units -> Sell instant, TP = x.  |
//| x = upper band value read live at shift0, the instant the new bar |
//| opens. bar0 = just-closed bar.                                    |
//+------------------------------------------------------------------+
void CheckAndTrade_UpperBand(int tf)
{
   double xArr[];
   ArraySetAsSeries(xArr, true);
   int bshift = Opt_BandShift1 ? 1 : 0;
   if(CopyBuffer(g_bb_handle[tf], 1, bshift, 1, xArr) <= 0)
   {
      Print("[", g_tfName[tf], "] Failed to read x (band shift0)");
      return;
   }
   double x = xArr[0];
   double bar0High = iHigh(_Symbol, g_tf[tf], 1);

   double thr_sell = (K_Threshold_Dollar > 0.0) ? K_Threshold_Dollar : (K_Threshold_Pct * 0.01 * x);
   if(bar0High - x > thr_sell)
   {
      ulong ticket = OpenOrder(ORDER_TYPE_SELL, x, "SELL", tf);
      if(ticket != 0)
         RegisterOneBarExit(tf, ticket, true, x, g_chaseFraction[tf]);
   }
}

//+------------------------------------------------------------------+
//| BUY: x2 - bar0.low > K_Threshold_Units -> Buy instant, TP = x2.   |
//| x2 = lower band value read live at shift0, the instant the new    |
//| bar opens. bar0 = just-closed bar.                                |
//+------------------------------------------------------------------+
void CheckAndTrade_LowerBand(int tf)
{
   double x2Arr[];
   ArraySetAsSeries(x2Arr, true);
   int bshift2 = Opt_BandShift1 ? 1 : 0;
   if(CopyBuffer(g_bb_handle[tf], 2, bshift2, 1, x2Arr) <= 0)
   {
      Print("[", g_tfName[tf], "] Failed to read x2 (lower band shift0)");
      return;
   }
   double x2 = x2Arr[0];
   double bar0Low = iLow(_Symbol, g_tf[tf], 1);

   double thr_buy = (K_Threshold_Dollar > 0.0) ? K_Threshold_Dollar : (K_Threshold_Pct * 0.01 * x2);
   if(x2 - bar0Low > thr_buy)
   {
      ulong ticket = OpenOrder(ORDER_TYPE_BUY, x2, "BUY", tf);
      if(ticket != 0)
         RegisterOneBarExit(tf, ticket, false, x2, g_chaseFraction[tf]);
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

   // unique name per optimization pass so a Complete-optimization queue doesn't
   // overwrite the same file on every pass -- encode every tunable that could vary
   string fname = InpCsvDumpName
      + "_K" + DoubleToString(K_Threshold_Pct, 2)
      + "_KD" + DoubleToString(K_Threshold_Dollar, 1)
      + "_f5-" + DoubleToString(M5_ChaseFraction, 3)
      + "_f15-" + DoubleToString(M15_ChaseFraction, 3)
      + "_f30-" + DoubleToString(M30_ChaseFraction, 3)
      + "_f1-" + DoubleToString(H1_ChaseFraction, 3)
      + "_tf" + IntegerToString(Opt_TfSelect)
      + "_fi" + IntegerToString(Opt_FracIdx)
      + "_bs" + (Opt_BandShift1 ? "1" : "0");

   int handle = FileOpen(fname + ".csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
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

   // built-in tester stats (equity/floating drawdown, consecutive win/loss streaks) --
   // these need MT5's own bar-by-bar equity tracking, not derivable from the closed-deal
   // log above, so pull them from TesterStatistics() into a second small file.
   int sh = FileOpen(fname + "_stats.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(sh != INVALID_HANDLE)
   {
      FileWrite(sh, "Stat", "Value");
      FileWrite(sh, "InitialDeposit", TesterStatistics(STAT_INITIAL_DEPOSIT));
      FileWrite(sh, "NetProfit",      TesterStatistics(STAT_PROFIT));
      FileWrite(sh, "BalanceDD_Money",TesterStatistics(STAT_BALANCE_DD));
      FileWrite(sh, "BalanceDD_Pct",  TesterStatistics(STAT_BALANCEDD_PERCENT));
      FileWrite(sh, "EquityDD_Money", TesterStatistics(STAT_EQUITY_DD));   // floating/unrealized DD
      FileWrite(sh, "EquityDD_Pct",   TesterStatistics(STAT_EQUITYDD_PERCENT));
      FileWrite(sh, "Trades",         TesterStatistics(STAT_TRADES));
      FileWrite(sh, "ProfitTrades",   TesterStatistics(STAT_PROFIT_TRADES));
      FileWrite(sh, "LossTrades",     TesterStatistics(STAT_LOSS_TRADES));
      FileWrite(sh, "GrossProfit",    TesterStatistics(STAT_GROSS_PROFIT));
      FileWrite(sh, "GrossLoss",      TesterStatistics(STAT_GROSS_LOSS));
      FileWrite(sh, "ExpectedPayoff", TesterStatistics(STAT_EXPECTED_PAYOFF));
      FileWrite(sh, "ProfitFactor",   TesterStatistics(STAT_PROFIT_FACTOR));
      FileClose(sh);
   }
   return(0.0);
}
//+------------------------------------------------------------------+
