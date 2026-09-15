//+------------------------------------------------------------------+
//|                                          preBB_Intrabar.mq5      |
//|  Variant of preBB.mq5: signal no longer waits for the bar to      |
//|  close. Every tick, checks the CURRENTLY FORMING bar's running    |
//|  high/low against the LIVE band value (both shift0) and fires     |
//|  the instant K_Threshold is satisfied -- not at bar close.        |
//|  TP = the live band value at the exact instant of firing.         |
//|  TP-chase mechanism after entry is UNCHANGED from preBB.mq5.       |
//|                                                                    |
//|  Signal (checked every tick, once per side per bar):               |
//|   thr = K_Threshold_Pct % of the band price                        |
//|   SELL: formingHigh - x  > thr -> Sell instant, TP=x (live x)      |
//|   BUY:  x2 - formingLow  > thr -> Buy instant,  TP=x2 (live x2)    |
//|  where formingHigh/Low = shift0 (still-open) bar's running extreme,|
//|  x/x2 = upper/lower band read live at shift0, same tick.           |
//|  Each side fires at most once per bar (flag reset on new bar).     |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.00"
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
input bool     InpDebugTpChase = false;             // if true (and InpCsvDumpName set): log every TP-chase update to <name>_tpchase.csv
input int      InpMaxBarsHold = 0;                  // force-close if TP not touched after this many bars (0 = chase forever)
input double   InpHardSLUnits = 0;                  // fixed SL distance from entry, price units (0 = no SL)
input bool     InpUseBandChase = false;             // true: TP re-pegs to the closed bar's live band value (next bar's band point) each bar instead of the EMA-fraction formula
input int      InpGlobalMaxConcurrent = 0;          // cap on open+pending positions across ALL 4 timeframes combined (0 = no cap, per-TF caps still apply)
input bool     InpSkipIfOtherTfLosing = false;      // don't open a new entry if any OTHER TF's position is currently floating-negative (correlated-move veto)
input bool     InpBlockH1M15M30Stack = false;       // don't let M15/M30/H1 all be open at once (the correlated-loss combo found in analysis) -- block the entry that would complete the triple, any direction
input bool     InpPreferSmallTf = false;            // if a "small" TF (M5/M15) is already open, skip a same-time "big" TF (M30/H1) entry -- let the faster TF trade alone instead of stacking
input bool     InpSkipAfterLossSameDir = false;     // don't let a TF re-fire the SAME direction again if its own last closed trade in that direction was a loss (chain-of-losses brake found in the Apr 2026 cluster analysis)
input int      InpLossCooldownBars = 20;            // bars to wait (this TF's own bars) after a same-direction loss before allowing that direction again -- prevents a permanent lockout
input bool     InpUseRSIGate = true;                 // require RSI(14, shift1) to confirm the direction is a real extreme, not mid-trend continuation (the losing RSI 50-70 zone found in analysis)
input double   InpRSIExtremity = 0;                  // symmetric distance from 50: SELL needs RSI>=50+X, BUY needs RSI<=50-X -- shared across all TF, used when Opt_TfSelect grids one TF in isolation
input double   M5_RSIExtremity  = 0;                 // per-TF extremity for combined runs (0 = off for that TF) -- M5: gate hurts (no losing mid-RSI zone found), leave off
input double   M15_RSIExtremity = 10;                // M15: strongest gate, narrowest losing-RSI zone
input double   M30_RSIExtremity = 5;
input double   H1_RSIExtremity  = 5;

input group "=== Timeframes ==="
input bool     Enable_M5   = true;                  // Run M5
input bool     Enable_M15  = true;                  // Run M15
input bool     Enable_M30  = true;                  // Run M30
input bool     Enable_H1   = true;                  // Run H1
input int      M5_Magic    = 211005;                // M5 magic (unique, different from preBB.mq5)
input int      M15_Magic   = 211015;                // M15 magic (unique)
input int      M30_Magic   = 211030;                // M30 magic (unique)
input int      H1_Magic    = 211060;                // H1 magic (unique)

input group "=== Trading Hours (server time, empty = all day) ==="
input string   M5_TradeHours  = "";
input string   M15_TradeHours = "";
input string   M30_TradeHours = "";
input string   H1_TradeHours  = "";

input group "=== Bollinger Band ==="
input int      BB_Period       = 20;
input double   BB_Deviation    = 2.0;
input ENUM_APPLIED_PRICE BB_Price = PRICE_CLOSE;

input group "=== Volatility filter (ATR ceiling, ref XAUUSD_RegimeBot_v6.mq5) ==="
input int      InpATRPeriod = 14;                   // ATR period, each TF measured on its own timeframe
input double   InpMaxATR    = 0;                    // 0 = off; else skip a new entry when this TF's ATR(shift1) >= this (price units) -- one shared ceiling, kept for the earlier test
input double   M5_MinATR  = 0;                      // 0 = off; else skip M5 entry when its ATR(shift1) < this -- per-TF floor (low-ATR quintile was the losing one, not high)
input double   M15_MinATR = 0;
input double   M30_MinATR = 0;
input double   H1_MinATR  = 0;

input group "=== Price Unit ==="
input double   PriceUnit       = 1.0;

input group "=== Signal (per-TF K, so each TF can run its own tuned threshold together) ==="
input double   K_Threshold_Pct = 0.55;              // fallback used when Opt_TfSelect is set (single-TF grid runs) -- combined runs use the Mx_K_Threshold_Pct below
input double   K_Threshold_Dollar = 0.0;            // if >0, use this fixed $ threshold instead of Pct (all TF)
input double   M5_K_Threshold_Pct  = 0.40;
input double   M15_K_Threshold_Pct = 0.60;
input double   M30_K_Threshold_Pct = 0.60;
input double   H1_K_Threshold_Pct  = 0.60;

input group "=== TP chase fraction (per-TF, unchanged mechanism) ==="
input double   M5_ChaseFraction  = 0.5;
input double   M15_ChaseFraction = 0.5;
input double   M30_ChaseFraction = 0.5;
input double   H1_ChaseFraction  = 0.6;

input group "=== Optimizer helpers (leave -1 for normal use) ==="
input int      Opt_TfSelect = -1;                    // -1: use Enable_* ; 0=M5 1=M15 2=M30 3=H1 only ; 4=all four
input int      Opt_FracIdx  = -1;                    // -1: use Mx_ChaseFraction ; 0=0.5 1=0.6 2=2/3 3=0.75 for all TF

input group "=== Per-Timeframe Order Limits ==="
input int      M5_MaxConcurrentOrders  = 3;
input int      M15_MaxConcurrentOrders = 3;
input int      M30_MaxConcurrentOrders = 3;
input int      H1_MaxConcurrentOrders  = 3;
input int      M5_CooldownBars  = 0;
input int      M15_CooldownBars = 0;
input int      M30_CooldownBars = 0;
input int      H1_CooldownBars  = 0;

input group "=== Trade Management ==="
input double   LotSize         = 0.01;
input int      Slippage        = 10;

input group "=== Daily Profit Stop (all enabled timeframes/magics) ==="
input double   DailyProfitStopPct = 0.0;
input double   DailyProfitStopUSD = 0.0;
input int      SnapHour            = 0;

//--- Per-timeframe state
ENUM_TIMEFRAMES g_tf[TF_COUNT];
int             g_magic[TF_COUNT];
bool            g_enabled[TF_COUNT];
int             g_bb_handle[TF_COUNT];
int             g_atr_handle[TF_COUNT];
int             g_rsi_handle[TF_COUNT];
int             g_stoch_handle[TF_COUNT];
double          g_maxATRSeen[TF_COUNT]; // debug: highest ATR(shift1) observed per TF this run
double          g_minATR[TF_COUNT]; // per-TF ATR floor (0 = off)
double          g_rsiExtremity[TF_COUNT]; // per-TF RSI gate strength (0 = off)
bool            g_lastWasLoss[TF_COUNT][2]; // [tf][0=SELL,1=BUY] -- was this TF+direction's last closed trade a loss?
int             g_lossCooldownLeft[TF_COUNT][2]; // bars left before that TF+direction can fire again
datetime        g_lastBarTime[TF_COUNT];
datetime        g_lastTradeBarTime[TF_COUNT];
string          g_tfName[TF_COUNT];
string          g_tradeHours[TF_COUNT];
int             g_maxConcurrent[TF_COUNT];
int             g_cooldownBars[TF_COUNT];
double          g_chaseFraction[TF_COUNT];
double          g_kPct[TF_COUNT]; // per-TF K threshold (%)
bool            g_firedUpper[TF_COUNT]; // this bar's SELL side already fired
bool            g_firedLower[TF_COUNT]; // this bar's BUY side already fired

//--- daily profit stop state
double   g_snapshotBalance   = 0.0;
datetime g_snapshotDay       = 0;
bool     g_profitStopHit     = false;
double   g_realizedSinceSnap = 0.0;
int      g_ourOpenCount      = 0;

bool IsOurMagic(long magic)
  {
   for(int i = 0; i < TF_COUNT; i++)
      if(magic == g_magic[i]) return true;
   return false;
  }

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

   // per-TF K: single-TF grid runs (Opt_TfSelect 0-3) use the shared K_Threshold_Pct
   // input (so the optimizer only has to range one field); combined 4-TF runs use
   // each TF's own Mx_K_Threshold_Pct.
   if(Opt_TfSelect >= 0 && Opt_TfSelect <= 3)
   {
      for(int k = 0; k < TF_COUNT; k++) g_kPct[k] = K_Threshold_Pct;
   }
   else
   {
      g_kPct[IDX_M5] = M5_K_Threshold_Pct;   g_kPct[IDX_M15] = M15_K_Threshold_Pct;
      g_kPct[IDX_M30] = M30_K_Threshold_Pct; g_kPct[IDX_H1] = H1_K_Threshold_Pct;
   }

   g_minATR[IDX_M5] = M5_MinATR;   g_minATR[IDX_M15] = M15_MinATR;
   g_minATR[IDX_M30] = M30_MinATR; g_minATR[IDX_H1] = H1_MinATR;

   // per-TF RSI extremity: single-TF grid runs (Opt_TfSelect 0-3) use the shared
   // InpRSIExtremity input (one grid dimension); combined 4-TF runs use each TF's own.
   if(Opt_TfSelect >= 0 && Opt_TfSelect <= 3)
   {
      for(int k = 0; k < TF_COUNT; k++) g_rsiExtremity[k] = InpRSIExtremity;
   }
   else
   {
      g_rsiExtremity[IDX_M5] = M5_RSIExtremity;   g_rsiExtremity[IDX_M15] = M15_RSIExtremity;
      g_rsiExtremity[IDX_M30] = M30_RSIExtremity; g_rsiExtremity[IDX_H1] = H1_RSIExtremity;
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
      g_atr_handle[i] = INVALID_HANDLE;
      g_rsi_handle[i] = INVALID_HANDLE;
      g_stoch_handle[i] = INVALID_HANDLE;
      g_maxATRSeen[i] = 0;
      g_lastWasLoss[i][0] = false;
      g_lastWasLoss[i][1] = false;
      g_lossCooldownLeft[i][0] = 0;
      g_lossCooldownLeft[i][1] = 0;
      g_lastBarTime[i] = 0;
      g_lastTradeBarTime[i] = 0;
      g_firedUpper[i] = false;
      g_firedLower[i] = false;

      if(!g_enabled[i])
         continue;

      g_bb_handle[i] = iBands(_Symbol, g_tf[i], BB_Period, 0, BB_Deviation, BB_Price);
      if(g_bb_handle[i] == INVALID_HANDLE)
      {
         Print("Failed to init Bollinger Band for ", g_tfName[i]);
         return(INIT_FAILED);
      }

      g_atr_handle[i] = iATR(_Symbol, g_tf[i], InpATRPeriod);
      if(g_atr_handle[i] == INVALID_HANDLE)
      {
         Print("Failed to init ATR for ", g_tfName[i]);
         return(INIT_FAILED);
      }

      g_rsi_handle[i] = iRSI(_Symbol, g_tf[i], 14, PRICE_CLOSE);
      g_stoch_handle[i] = iStochastic(_Symbol, g_tf[i], 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      if(g_rsi_handle[i] == INVALID_HANDLE || g_stoch_handle[i] == INVALID_HANDLE)
      {
         Print("Failed to init RSI/Stoch for ", g_tfName[i]);
         return(INIT_FAILED);
      }
   }

   g_snapshotBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
   g_snapshotDay       = 0;
   g_profitStopHit     = false;
   g_realizedSinceSnap = 0.0;

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
//| TP chase (UNCHANGED mechanism vs preBB.mq5)                       |
//+------------------------------------------------------------------+
#define MAX_TPCHASE_TRACK 500
ulong  g_tpTicket[MAX_TPCHASE_TRACK];
bool   g_tpIsSell[MAX_TPCHASE_TRACK];
int    g_tpTf[MAX_TPCHASE_TRACK];
int    g_tpBars[MAX_TPCHASE_TRACK];
double g_tpLastTp[MAX_TPCHASE_TRACK];
double g_tpFraction[MAX_TPCHASE_TRACK];
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
         DropTpChaseSlot(i);
         continue;
      }

      g_tpBars[i]++;
      if(InpMaxBarsHold > 0 && g_tpBars[i] >= InpMaxBarsHold)
      {
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
         newTp = NormalizeDouble(g_tpIsSell[i] ? yArr[0] : y2Arr[0], digits); // next bar's band point
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
      g_tpLastTp[i] = newTp; // unused as an anchor in band-chase mode, harmless to keep updated

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
         if(trade.PositionClose(g_tpTicket[i]))
            DropTpChaseSlot(i);
         else
            PrintFormat("[%s] Force-close (TP invalid or modify failed) failed ticket %I64u: %u, will retry next bar", g_tfName[tf], g_tpTicket[i], trade.ResultRetcode());
      }
   }
}

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
            PrintFormat("preBB_Intrabar: profit-stop close of #%I64u failed, retcode %u", ticket, code);
            break;
         }
      }
   }
}

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
         PrintFormat("preBB_Intrabar: profit-stop cancel of pending #%I64u failed, retcode %u", ticket, result.retcode);
   }
}

double OurFloatingPnL()
{
   if(g_ourOpenCount <= 0) return 0.0;

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

void LogProgress(string label)
{
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double ourPnLToday = g_realizedSinceSnap + OurFloatingPnL();

   double pctThreshold = (DailyProfitStopPct > 0.0) ? g_snapshotBalance * (DailyProfitStopPct / 100.0) : DBL_MAX;
   double usdThreshold = (DailyProfitStopUSD > 0.0) ? DailyProfitStopUSD : DBL_MAX;
   double goalUsd       = MathMin(pctThreshold, usdThreshold);
   double goalPct        = (g_snapshotBalance > 0.0 && goalUsd < DBL_MAX) ? goalUsd / g_snapshotBalance * 100.0 : 0.0;

   double earnedUsd = ourPnLToday;
   double earnedPct = (g_snapshotBalance > 0.0) ? earnedUsd / g_snapshotBalance * 100.0 : 0.0;

   double leftUsd = (goalUsd < DBL_MAX) ? goalUsd - earnedUsd : 0.0;
   double leftPct = (goalUsd < DBL_MAX) ? goalPct - earnedPct : 0.0;

   int h = FileOpen("preBB_Intrabar_Balance.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
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
      double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      g_realizedSinceSnap += pnl;

      // same-TF, same-direction post-loss brake: a closing BUY deal means the
      // position being closed was a SELL (bought back to cover), and vice versa.
      int tf = -1;
      for(int i = 0; i < TF_COUNT; i++) if(g_magic[i] == magic) tf = i;
      if(tf >= 0)
      {
         ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         bool wasSell = (dtype == DEAL_TYPE_BUY); // closing buy-back -> position was SELL
         int dirIdx = wasSell ? 0 : 1;
         g_lastWasLoss[tf][dirIdx] = (pnl < 0);
         if(pnl < 0) g_lossCooldownLeft[tf][dirIdx] = InpLossCooldownBars;
      }
   }
}

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
      PrintFormat("preBB_Intrabar: %02d:00 balance snapshot %.2f", SnapHour, g_snapshotBalance);
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
         PrintFormat("preBB_Intrabar: this EA's PnL since snapshot +%.2f reached the %s threshold (+%.2f). "
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
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(g_bb_handle[i] != INVALID_HANDLE)
         IndicatorRelease(g_bb_handle[i]);
      if(g_atr_handle[i] != INVALID_HANDLE)
         IndicatorRelease(g_atr_handle[i]);
      if(g_rsi_handle[i] != INVALID_HANDLE)
         IndicatorRelease(g_rsi_handle[i]);
      if(g_stoch_handle[i] != INVALID_HANDLE)
         IndicatorRelease(g_stoch_handle[i]);
   }
}

//+------------------------------------------------------------------+
//| New-bar edge detector: resets the per-bar "already fired" flags   |
//| and drives once-per-bar housekeeping (TP-chase step).             |
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
//| true if any OTHER TF's open position (our magics, this symbol) is |
//| currently floating-negative. Used to veto a new entry so we don't |
//| stack a fresh order on top of a move that's already hurting a     |
//| different TF -- the correlated-loss signature found in the        |
//| H1+M15+M30 stack analysis.                                        |
//+------------------------------------------------------------------+
bool AnyOtherTfInLoss(int tf)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(magic)) continue;
      if(magic == g_magic[tf]) continue; // only OTHER TFs count
      double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pnl < 0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| true if the OTHER TWO of {M15,M30,H1} both already have an open   |
//| position -- i.e. this entry would complete the 3-way stack that   |
//| analysis showed is a reproducible correlated-loss combo. M5 is    |
//| not part of the stack this gate watches. Direction-agnostic.      |
//+------------------------------------------------------------------+
bool WouldCompleteThreeWayStack(int tf)
{
   if(tf != IDX_M15 && tf != IDX_M30 && tf != IDX_H1)
      return false; // M5 not part of the watched combo

   int others[2]; int oi = 0;
   if(tf != IDX_M15) others[oi++] = IDX_M15;
   if(tf != IDX_M30) others[oi++] = IDX_M30;
   if(tf != IDX_H1)  others[oi++] = IDX_H1;

   for(int k = 0; k < 2; k++)
      if(CountOpenPositions(g_magic[others[k]]) <= 0)
         return false; // one of the other two isn't open -- no stack completed

   return true; // both other two already open -- this entry would complete the triple
}

//+------------------------------------------------------------------+
//| true if tf is a "big" (slow) TF -- M30 or H1 -- and a "small"     |
//| (fast) TF -- M5 or M15 -- already has an open position. Lets the   |
//| faster TF trade alone instead of the slow TF piling on top of it. |
//+------------------------------------------------------------------+
bool BigTfBlockedBySmall(int tf)
{
   if(tf != IDX_M30 && tf != IDX_H1)
      return false; // only gates the big TFs

   if(CountOpenPositions(g_magic[IDX_M5]) > 0)  return true;
   if(CountOpenPositions(g_magic[IDX_M15]) > 0) return true;
   return false;
}

//+------------------------------------------------------------------+
//| true if this TF's own ATR(shift1, closed bar) is at/above the      |
//| ceiling -- volatility filter, ref XAUUSD_RegimeBot_v6.mq5's ATR    |
//| spike gate (that one is relative to a rolling average; this one   |
//| is a flat $ ceiling per the user's request).                      |
//+------------------------------------------------------------------+
bool ATRTooHigh(int tf)
{
   double atrArr[]; ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(g_atr_handle[tf], 0, 1, 1, atrArr) <= 0)
      return false;
   if(atrArr[0] > g_maxATRSeen[tf]) g_maxATRSeen[tf] = atrArr[0]; // debug tracker, harmless in live use
   if(InpMaxATR <= 0) return false;
   return atrArr[0] >= InpMaxATR;
}

//+------------------------------------------------------------------+
//| true if this TF's own ATR(shift1) is BELOW its per-TF floor --    |
//| analysis showed the LOWEST ATR quintile is where losses cluster   |
//| on every TF, not the highest, so this is a floor, not a ceiling.  |
//+------------------------------------------------------------------+
bool ATRTooLow(int tf)
{
   if(g_minATR[tf] <= 0) return false;
   double atrArr[]; ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(g_atr_handle[tf], 0, 1, 1, atrArr) <= 0)
      return false;
   return atrArr[0] < g_minATR[tf];
}

//+------------------------------------------------------------------+
//| RSI confirmation: analysis showed the losing zone for SELL/BUY    |
//| entries is mid-momentum RSI (~50-70), not a true overbought/       |
//| oversold extreme. isSell=true checks RSI is high enough (SELL      |
//| needs overbought); isSell=false checks RSI is low enough (BUY      |
//| needs oversold).                                                   |
//+------------------------------------------------------------------+
bool RSIConfirms(int tf, bool isSell)
{
   if(!InpUseRSIGate) return true;
   if(g_rsiExtremity[tf] <= 0) return true; // gate off for this TF
   double rsiArr[]; ArraySetAsSeries(rsiArr, true);
   if(CopyBuffer(g_rsi_handle[tf], 0, 1, 1, rsiArr) <= 0)
      return true; // fail open if indicator not ready
   double rsi = rsiArr[0];
   double sellMin = 50.0 + g_rsiExtremity[tf];
   double buyMax  = 50.0 - g_rsiExtremity[tf];
   return isSell ? (rsi >= sellMin) : (rsi <= buyMax);
}

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
//| Open market order with absolute TP price. UNCHANGED vs preBB.mq5. |
//+------------------------------------------------------------------+
ulong OpenOrder(ENUM_ORDER_TYPE orderType, double tpPrice, string comment, int tf)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   string fullComment = g_tfName[tf] + "_" + comment;

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

   if(InpCsvDumpName != "")
   {
      double atrArr[]; ArraySetAsSeries(atrArr, true);
      double atrAtEntry = (CopyBuffer(g_atr_handle[tf], 0, 1, 1, atrArr) > 0) ? atrArr[0] : -1;

      double rsiArr[]; ArraySetAsSeries(rsiArr, true);
      double rsiAtEntry = (CopyBuffer(g_rsi_handle[tf], 0, 1, 1, rsiArr) > 0) ? rsiArr[0] : -1;

      double stochMainArr[]; ArraySetAsSeries(stochMainArr, true);
      double stochSigArr[]; ArraySetAsSeries(stochSigArr, true);
      double stochMain = (CopyBuffer(g_stoch_handle[tf], 0, 1, 1, stochMainArr) > 0) ? stochMainArr[0] : -1;
      double stochSig  = (CopyBuffer(g_stoch_handle[tf], 1, 1, 1, stochSigArr) > 0) ? stochSigArr[0] : -1;

      long tickVolume = iVolume(_Symbol, g_tf[tf], 1);

      int th = FileOpen(InpCsvDumpName + "_entryatr.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
      if(th != INVALID_HANDLE)
      {
         FileSeek(th, 0, SEEK_END);
         FileWrite(th, (long)result.order, g_tfName[tf], fullComment, atrAtEntry, rsiAtEntry, stochMain, stochSig, tickVolume);
         FileClose(th);
      }
   }

   return result.order;
}

//+------------------------------------------------------------------+
//| INTRABAR SELL: live upper band x vs the CURRENTLY FORMING bar's   |
//| running high (shift0, updates every tick) -- no bar-close wait.   |
//| formingHigh - x > thr -> Sell instant at market, TP = x (live).   |
//+------------------------------------------------------------------+
void CheckAndTrade_UpperBand(int tf)
{
   if(g_firedUpper[tf]) return; // already fired this bar
   if(InpSkipAfterLossSameDir && g_lossCooldownLeft[tf][0] > 0) return; // last SELL on this TF lost -- cooling down before chaining another
   if(!RSIConfirms(tf, true)) return; // SELL needs overbought RSI, not mid-trend

   double xArr[];
   ArraySetAsSeries(xArr, true);
   if(CopyBuffer(g_bb_handle[tf], 1, 0, 1, xArr) <= 0)
      return; // live band not ready yet this tick
   double x = xArr[0];
   double formingHigh = iHigh(_Symbol, g_tf[tf], 0); // running high of the still-open bar

   double thr_sell = (K_Threshold_Dollar > 0.0) ? K_Threshold_Dollar : (g_kPct[tf] * 0.01 * x);
   if(formingHigh - x > thr_sell)
   {
      ulong ticket = OpenOrder(ORDER_TYPE_SELL, x, "SELL", tf);
      g_firedUpper[tf] = true; // one shot per bar regardless of fill result
      if(ticket != 0)
         RegisterOneBarExit(tf, ticket, true, x, g_chaseFraction[tf]);
   }
}

//+------------------------------------------------------------------+
//| INTRABAR BUY: live lower band x2 vs the CURRENTLY FORMING bar's   |
//| running low (shift0, updates every tick) -- no bar-close wait.    |
//| x2 - formingLow > thr -> Buy instant at market, TP = x2 (live).   |
//+------------------------------------------------------------------+
void CheckAndTrade_LowerBand(int tf)
{
   if(g_firedLower[tf]) return; // already fired this bar
   if(InpSkipAfterLossSameDir && g_lossCooldownLeft[tf][1] > 0) return; // last BUY on this TF lost -- cooling down before chaining another
   if(!RSIConfirms(tf, false)) return; // BUY needs oversold RSI, not mid-trend

   double x2Arr[];
   ArraySetAsSeries(x2Arr, true);
   if(CopyBuffer(g_bb_handle[tf], 2, 0, 1, x2Arr) <= 0)
      return;
   double x2 = x2Arr[0];
   double formingLow = iLow(_Symbol, g_tf[tf], 0); // running low of the still-open bar

   double thr_buy = (K_Threshold_Dollar > 0.0) ? K_Threshold_Dollar : (g_kPct[tf] * 0.01 * x2);
   if(x2 - formingLow > thr_buy)
   {
      ulong ticket = OpenOrder(ORDER_TYPE_BUY, x2, "BUY", tf);
      g_firedLower[tf] = true;
      if(ticket != 0)
         RegisterOneBarExit(tf, ticket, false, x2, g_chaseFraction[tf]);
   }
}

//+------------------------------------------------------------------+
//| Runs every tick (not gated by new-bar) -- that's what makes this  |
//| variant fire the instant the threshold is crossed intrabar.       |
//+------------------------------------------------------------------+
void CheckAndTrade(int tf)
{
   if(g_profitStopHit)
      return;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(!IsTradeHourAllowed(g_tradeHours[tf], now.hour))
      return;

   int cooldown = g_cooldownBars[tf];
   if(cooldown > 0 && g_lastTradeBarTime[tf] != 0)
   {
      int barsSinceLastTrade = iBarShift(_Symbol, g_tf[tf], g_lastTradeBarTime[tf], false);
      if(barsSinceLastTrade <= cooldown)
         return;
   }

   if(InpGlobalMaxConcurrent > 0 && CountAllOurOpenAndPending() >= InpGlobalMaxConcurrent)
      return;

   if(InpSkipIfOtherTfLosing && AnyOtherTfInLoss(tf))
      return;

   if(InpBlockH1M15M30Stack && WouldCompleteThreeWayStack(tf))
      return;

   if(InpPreferSmallTf && BigTfBlockedBySmall(tf))
      return;

   if(ATRTooHigh(tf))
      return;

   if(ATRTooLow(tf))
      return;

   int cap = g_maxConcurrent[tf];
   int magic = g_magic[tf];

   if(CountOpenPositions(magic) + CountPendingOrders(magic) < cap)
      CheckAndTrade_UpperBand(tf);

   if(CountOpenPositions(magic) + CountPendingOrders(magic) < cap)
      CheckAndTrade_LowerBand(tf);
}

//+------------------------------------------------------------------+
//| Expert tick function. New-bar edge only resets fired-flags and    |
//| runs the TP-chase step; the signal itself is checked EVERY tick.  |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateProfitStop();

   for(int tf = 0; tf < TF_COUNT; tf++)
   {
      if(!g_enabled[tf])
         continue;

      if(IsNewBar(tf))
      {
         g_firedUpper[tf] = false;
         g_firedLower[tf] = false;
         if(g_lossCooldownLeft[tf][0] > 0) g_lossCooldownLeft[tf][0]--;
         if(g_lossCooldownLeft[tf][1] > 0) g_lossCooldownLeft[tf][1]--;
         UpdateOneBarExit(tf); // force-close any position still open one bar after entry
         ATRTooHigh(tf); // unconditional call so g_maxATRSeen tracks every bar, not just gated ones
      }

      CheckAndTrade(tf); // intrabar: fires the instant thr is crossed, not just on new bar
   }
}

//+------------------------------------------------------------------+
//| Tester-only CSV dump. Same shape as preBB.mq5's, filename encodes |
//| K so a Complete-optimization grid never collides.                 |
//+------------------------------------------------------------------+
double OnTester()
{
   if(InpCsvDumpName == "") return(0.0);
   if(!HistorySelect(0, TimeCurrent())) return(0.0);

   string fname = InpCsvDumpName
      + "_K" + DoubleToString(K_Threshold_Pct, 2)
      + "_k5-" + DoubleToString(M5_K_Threshold_Pct, 2)
      + "_k15-" + DoubleToString(M15_K_Threshold_Pct, 2)
      + "_k30-" + DoubleToString(M30_K_Threshold_Pct, 2)
      + "_k1-" + DoubleToString(H1_K_Threshold_Pct, 2)
      + "_tf" + IntegerToString(Opt_TfSelect)
      + "_fi" + IntegerToString(Opt_FracIdx)
      + "_atr" + DoubleToString(InpMaxATR, 1)
      + "_min5-" + DoubleToString(M5_MinATR, 1)
      + "_min15-" + DoubleToString(M15_MinATR, 1)
      + "_min30-" + DoubleToString(M30_MinATR, 1)
      + "_min1-" + DoubleToString(H1_MinATR, 1)
      + "_rsix" + DoubleToString(InpRSIExtremity, 1)
      + "_rx5-" + DoubleToString(M5_RSIExtremity, 1)
      + "_rx15-" + DoubleToString(M15_RSIExtremity, 1)
      + "_rx30-" + DoubleToString(M30_RSIExtremity, 1)
      + "_rx1-" + DoubleToString(H1_RSIExtremity, 1);

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

   int sh = FileOpen(fname + "_stats.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(sh != INVALID_HANDLE)
   {
      FileWrite(sh, "Stat", "Value");
      FileWrite(sh, "InitialDeposit", TesterStatistics(STAT_INITIAL_DEPOSIT));
      FileWrite(sh, "NetProfit",      TesterStatistics(STAT_PROFIT));
      FileWrite(sh, "BalanceDD_Money",TesterStatistics(STAT_BALANCE_DD));
      FileWrite(sh, "BalanceDD_Pct",  TesterStatistics(STAT_BALANCEDD_PERCENT));
      FileWrite(sh, "EquityDD_Money", TesterStatistics(STAT_EQUITY_DD));
      FileWrite(sh, "EquityDD_Pct",   TesterStatistics(STAT_EQUITYDD_PERCENT));
      FileWrite(sh, "Trades",         TesterStatistics(STAT_TRADES));
      FileWrite(sh, "ProfitTrades",   TesterStatistics(STAT_PROFIT_TRADES));
      FileWrite(sh, "LossTrades",     TesterStatistics(STAT_LOSS_TRADES));
      FileWrite(sh, "GrossProfit",    TesterStatistics(STAT_GROSS_PROFIT));
      FileWrite(sh, "GrossLoss",      TesterStatistics(STAT_GROSS_LOSS));
      FileWrite(sh, "ExpectedPayoff", TesterStatistics(STAT_EXPECTED_PAYOFF));
      FileWrite(sh, "ProfitFactor",   TesterStatistics(STAT_PROFIT_FACTOR));
      FileWrite(sh, "MaxATR_M5",  g_maxATRSeen[IDX_M5]);
      FileWrite(sh, "MaxATR_M15", g_maxATRSeen[IDX_M15]);
      FileWrite(sh, "MaxATR_M30", g_maxATRSeen[IDX_M30]);
      FileWrite(sh, "MaxATR_H1",  g_maxATRSeen[IDX_H1]);
      FileClose(sh);
   }
   return(0.0);
}
//+------------------------------------------------------------------+
