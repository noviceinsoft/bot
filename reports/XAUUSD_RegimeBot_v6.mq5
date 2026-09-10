//+------------------------------------------------------------------+
//|                                      XAUUSD_RegimeBot_v6.mq5      |
//|  KHUNG THOI GIAN: H1 (thiet ke va kiem dinh CHI danh cho H1 -      |
//|  KHONG doi sang M15/M30/H4 ma khong toi uu + kiem dinh lai tu dau) |
//|                                                                    |
//|  v6 = v5 + bo DXY filter (do KHONG co gia tri, xem duoi) + nguong  |
//|  momentum BAT DOI XUNG (buy/sell rieng, tim qua grid tren ca mau   |
//|  toan bo VA mau non-bull rieng, khong chi walk-forward mot chieu)  |
//|                                                                    |
//|  v6.1 = FIX BUG NGHIEM TRONG: GetMarketRegime/CalculateNormalized  |
//|  Momentum/IsVolatilitySpike/CalculateRatioSignal deu doc buffer    |
//|  shift=0 (nen DANG HINH THANH, chua dong) thay vi shift=1 (nen da  |
//|  dong gan nhat). Chi CheckTrendFilter (MA50) lam dung shift=1 tu   |
//|  dau. Phat hien qua backtest that tren MT5 (broker feed, date      |
//|  2024-2026): so lenh 446 (thuc te) vs 356 (Python da kiem dinh)    |
//|  tren CUNG mot khoang thoi gian, PF tut xuong 1.18 (thuc te) vs    |
//|  1.63 (Python). Da sua 5 cho CopyBuffer/CopyClose tu shift=0 sang  |
//|  shift=1.                                                          |
//|                                                                    |
//|  v6.2 = SAU KHI FIX v6.1, van con lech 399 vs 356 lenh (cung feed  |
//|  broker MetaQuotes-Demo). Dieu tra bang debug log (Print ADX/ATR/  |
//|  momentum that cua MT5 moi nen) doi chieu voi Python: ADX cua MT5  |
//|  LECH RAT NHIEU so voi cong thuc Wilder tu viet trong Python (lech |
//|  trung binh 4 diem, co cho lech toi 40+ diem) - trong khi ATR/     |
//|  momentum/gia dong chi lech nhieu nho. XAC NHAN bang cach thay so  |
//|  ADX/ATR/momentum THAT cua MT5 vao dung logic backtest: ra n=520,  |
//|  PF=1.28, khop gan dung EA that (n=509, PF=1.31, lech ~2%) - chung |
//|  minh nguyen nhan CUOI CUNG la cong thuc ADX khac nhau, khong phai |
//|  bug code nao khac.                                                |
//|  -> TOI UU LAI ADXTrendThresh/ADXRangeThresh (28/15 -> 24/14) bang |
//|  grid-search TREN CHINH ADX THAT cua MT5 (train 2024-01->2025-09,  |
//|  test OOS 2025-09->2026-09): PF train 1.16->1.27, PF test OOS      |
//|  1.36->1.59, DD khong doi (~-309). Nguong 28/15 cu la toi uu NHAM  |
//|  tren thang do ADX khac (Python), khong phai thang do EA that dung.|
//|  KET QUA THAT (MT5, full 2024.01-2026.09, fixed lot 0.01, Forward= |
//|  No, random delay, every tick, ADX 24/14): PF=1.415, PnL=$2810.71, |
//|  MaxDD=3.12%, Sharpe=2.77, n=560. Day la con so DUNG NHAT (thay the|
//|  moi con so Python-only PF~1.63 truoc do).                         |
//|                                                                    |
//|  v6.3 = them News Filter (dung MQL5 Economic Calendar co san, bo   |
//|  qua tin hieu quanh tin USD quan trong NFP/FOMC/CPI...) + Max      |
//|  Drawdown Auto-Shutoff (ngung mo lenh moi khi equity sut >X% tu    |
//|  dinh, lenh dang mo van chay SL/TP binh thuong, khong tu reset -   |
//|  can restart EA). CA HAI CHUA duoc kiem dinh thong ke rieng (chua  |
//|  walk-forward/permutation) - la lop bao ve an toan bo sung, khong  |
//|  phai tin hieu giao dich. Chuoi thua nang nhat da tim thay          |
//|  (2026-04-02 -> 2026-04-21, 4 lenh SELL lien tiep, -$240): xay ra  |
//|  trong giai doan vang tang parabolic manh (4600->4835 trong 3 tuan)|
//|  - momentum H1 giam manh (SELL signal) nhung gia tiep tuc tang     |
//|  (whipsaw), MA50-Daily khong kip phan ung (lag qua xa so bien dong |
//|  H1 nhanh), ATR cao nhung tang dan deu (khong du dot bien 1 nen de |
//|  kich hoat vol-spike filter). News filter co the giam bot rui ro   |
//|  nay neu giai doan do trung tin lon, nhung day chu yeu la macro-   |
//|  driven multi-ngay chu khong phai 1 su kien - khong ky vong loai   |
//|  bo hoan toan loai whipsaw nay.                                    |
//|                                                                    |
//|  KET QUA KIEM DINH MOI NHAT (OOS ~2024-02 -> 2026-08):             |
//|  - FULL OOS: n=346 | WR=49.42% | PnL=2852.76 | PF=1.644 | MaxDD -395|
//|    (so voi baseline cu PnL=2043.46, PF=1.468 -> PnL +39.6%)         |
//|  - Permutation test FULL (n=300): p-value = 0.0000 (random mean=137,|
//|    P99=1549, PnL thuc vuot xa) - y nghia thong ke RAT MANH           |
//|  - Rieng mau NON-BULL (60-ngay return <3%, ~34% du lieu, loai bot   |
//|    3 quy giam/di ngang thuc su 2023Q3/2024Q4/2026Q2): PnL=304.41,   |
//|    PF=1.161 (so voi baseline cu PF=1.078 gan hoa von). Permutation  |
//|    test rieng cho mau nay: p=0.080 (KHONG dat p<0.05 chuan, nhung   |
//|    random trading trong giai doan non-bull LO trung binh -255,      |
//|    con chien luoc that duong +304 ~percentile 92 - huong dung       |
//|    nhung mau qua nho (n~115 lenh) de khang dinh chac chan)          |
//|  - KET LUAN: edge tren toan mau la THAT va manh. Tren giai doan     |
//|    KHONG bull-run rieng, edge van duong va tot hon truoc nhung      |
//|    CHUA du du lieu de chung minh chac chan o muc y nghia chuan.     |
//|    Dung ky vong ket qua nhu bull-run 2023-2026 se lap lai; theo doi |
//|    sat performance qua forward test, dac biet trong giai doan gia  |
//|    vang di ngang/giam.                                              |
//|                                                                    |
//|  PHAT HIEN QUAN TRONG dan den thay doi nay:                        |
//|  - DXY filter: da KIEM TRA LAI va thay conditional IC ~0 (p=0.81)  |
//|    - KHONG loc duoc gi ca. Bo DXY filter: PF gan nhu khong doi      |
//|    (1.468->1.460) nhung PnL TANG (2043->2317, do cho qua nhieu lenh |
//|    tot hon ma khong tang lenh xau). Ghi chu cu "DXY DA KIEM DINH CO |
//|    LOI" la SAI, co le do kiem dinh truoc khong du chat che.         |
//|  - MA50-Daily filter: XAC NHAN THAT SU co gia tri (conditional      |
//|    IC=0.107, p=1.3e-13). Bo no lam PF sup xuong 1.152, PnL giam gan |
//|    nua. GIU LAI, day la filter quan trong nhat.                     |
//|  - Momentum: gia tri thong ke that CHI o vung cuc doan. Toan bo giai|
//|    doan test co drift tang gia manh (+137%, $1948->$4611) khien     |
//|    momentum-BUY o vung vua phai (nguong cu 1.0) trong nhu co edge   |
//|    nhung phan lon la "an theo" bull run, khong phai du bao that.    |
//|    Tren mau non-bull: BUY o nguong cu LO (PF 0.779), SELL van co    |
//|    lai (PF 1.178). Nguong bat doi xung buy=1.5/sell=2.0 (chon qua   |
//|    grid tren ca 2 mau, khong chi 1 mau) cho ket qua tot hon tren ca |
//|    hai: full OOS PF 1.644, non-bull PF 1.161.                       |
//|                                                                    |
//|  4 LOP FILTER (theo thu tu kiem tra):                              |
//|  1. Regime detection (ADX): TREND >=28 / RANGE <=15 / vung xam bo qua|
//|  2. Huong tin hieu: Momentum bat doi xung(TREND) hoac XAU/XAG-ratio |
//|     co gate(RANGE)                                                  |
//|  3. Xu huong dai han MA50-Daily: chi BUY tren MA50, chi SELL duoi MA50|
//|  4. Volatility spike: bo qua tin hieu neu ATR hien tai > 2x ATR TB   |
//|     480 nen gan nhat (tranh whipsaw sau cu soc gia)                 |
//|                                                                    |
//|  Ratio-signal (nhanh RANGE): ratio_change_5 > 0.014 -> SELL,        |
//|  < -0.01 -> BUY, CHI khi ratio_change_20 cung dau va |gia tri| >     |
//|  0.02 (gate xac nhan dang trong xu huong phan ky da thiet lap).     |
//|  CANH BAO: tin hieu nay chi co y nghia thong ke RO RET tu ~2025-08  |
//|  tro di, chua kiem chung truoc do - CUONG DO thay doi theo regime   |
//|  thi truong, KHONG phai quy luat co dinh. Rieng nhanh nay dong gop  |
//|  rat it trong mau non-bull (gate qua chat, hau nhu khong kich hoat).|
//|                                                                    |
//|  VAN CON THIEU truoc khi ban ra thi truong:                        |
//|  - News filter (tranh vao lenh quanh NFP/FOMC/CPI)                 |
//|  - Gioi han max drawdown de tu tat bot                             |
//|  - Test tren nhieu broker/spread khac nhau, forward test demo       |
//|  - Theo doi rieng performance trong giai doan gia vang di ngang/    |
//|    giam de xac nhan edge ngoai bull-run (permutation p=0.080, chua  |
//|    chac chan o muc chuan do mau nho)                                |
//+------------------------------------------------------------------+
#property copyright "XAUUSD RegimeBot v6.3 (H1) - them News Filter (Economic Calendar) + Max-DD Auto-Shutoff"
#property version   "0.63"
#property strict

//--- Input parameters
input group "=== General ==="
input int      InpMagicNumber      = 20260907;  // Magic number
input bool     InpDebugLog         = false;     // TAM THOI: in ADX/ATR/momentum moi nen ra Journal de doi chieu voi Python (tat khi chay that)

input group "=== Regime Detection (ADX) - THAM SO SAU WALK-FORWARD ==="
input int      InpADXPeriod        = 14;
input double   InpADXTrendThresh   = 24.0;      // (v6.2) toi uu lai tren ADX THAT cua MT5 (28 cu toi uu nham tren cong thuc Python)
input double   InpADXRangeThresh   = 14.0;      // (v6.2) toi uu lai tren ADX THAT cua MT5

input group "=== Momentum (ATR-normalized) - NGUONG BAT DOI XUNG sau kiem dinh ==="
input int      InpMomLookback      = 10;
input int      InpATRPeriod        = 14;
input double   InpMomBuyThresh     = 1.5;       // mom_norm > nguong nay -> BUY (grid-search tren ca full-sample va non-bull)
input double   InpMomSellThresh    = 2.0;       // mom_norm < -nguong nay -> SELL

input group "=== XAU/XAG Ratio Signal (thay the Z-score o nhanh RANGE) ==="
input string   InpXAGSymbol         = "XAGUSD"; // Ten symbol bac tren broker (kiem tra Market Watch)
input bool     InpUseRatioSignal    = true;     // Bat/tat nhanh ratio - CANH BAO: chua kiem chung qua nhieu regime, xem comment dau file
input int      InpRatioChangeBars   = 5;        // So nen tinh % thay doi ty le XAU/XAG (ratio_change_5)
input double   InpRatioSellThresh   = 0.014;    // ratio_change_5 > nguong nay -> SELL (tim qua walk-forward)
input double   InpRatioBuyThresh    = 0.010;    // ratio_change_5 < -nguong nay -> BUY (tim qua walk-forward)
input bool     InpUseRatioGate      = true;     // Gate xac nhan: chi tin nhan tin hieu 5-nen khi nam trong xu huong phan ky da thiet lap
input int      InpRatioGateBars     = 20;       // So nen tinh ratio_change dai han de xac nhan xu huong (ratio_change_20)
input double   InpRatioGateThresh   = 0.02;     // |ratio_change_20| phai vuot nguong nay VA cung dau voi ratio_change_5

input group "=== Risk Management ==="
input double   InpATR_SL_Mult      = 2.0;       // SL = ATR * mult (CHUA toi uu rieng, dung tam)
input double   InpATR_TP_Mult      = 3.0;       // TP = ATR * mult (CHUA toi uu rieng, dung tam)
input double   InpMaxSpreadPoints  = 500;       // Khong vao lenh neu spread vuot muc nay (points)

input group "=== Position Sizing (theo % risk) ==="
input bool     InpUseRiskPercent   = true;      // true = tinh lot theo % risk; false = dung lot co dinh
input double   InpRiskPercent      = 1.0;       // % von risk moi lenh (neu InpUseRiskPercent = true)
input double   InpFixedLotSize     = 0.01;      // Lot co dinh (chi dung neu InpUseRiskPercent = false)
input double   InpMaxLotSize       = 5.0;       // Tran an toan - khong bao gio vuot muc nay du risk% tinh ra bao nhieu

input group "=== Trend Filter (MA50 Daily) - DA KIEM DINH CO LOI ==="
input bool     InpUseTrendFilter   = true;      // Chi BUY khi gia > MA50-Daily, chi SELL khi gia < MA50-Daily
input int      InpTrendMAPeriod    = 50;        // Period cua MA tren khung NGAY (KHONG phai H1)

input group "=== Volatility Spike Filter - DA KIEM DINH CO LOI ==="
input bool     InpUseVolFilter     = true;      // Bo qua tin hieu khi bien dong dot bien bat thuong
input int      InpVolRefBars       = 480;       // So nen H1 dung lam tham chieu ATR trung binh (~20 ngay)
input double   InpVolSpikeMultiplier = 2.0;     // Nguong: ATR hien tai > X lan ATR trung binh -> bo qua

input group "=== News Filter (Economic Calendar) - CHUA kiem dinh thong ke ==="
input bool     InpUseNewsFilter    = true;      // Bo qua tin hieu quanh tin USD quan trong (NFP/FOMC/CPI...)
input int      InpNewsMinutesBefore = 30;       // Khong vao lenh N phut TRUOC tin quan trong sap toi
input int      InpNewsMinutesAfter  = 30;       // Khong vao lenh N phut SAU tin quan trong vua ra (bien dong con manh)

input group "=== Max Drawdown Auto-Shutoff - CHUA kiem dinh thong ke ==="
input bool     InpUseMaxDDShutoff  = true;      // Tu dong ngung MO LENH MOI (khong dong lenh dang mo) khi DD vuot nguong
input double   InpMaxDDPercent     = 15.0;      // % sut giam tu dinh equity cao nhat -> kich hoat shutoff

//--- Handles cho indicator
int handleADX;
int handleATR;
int handleTrendMA;    // MA50 tren khung NGAY (D1) - filter xu huong dai han

datetime lastBarTime = 0;  // de dam bao chi xu ly 1 lan/nen moi (tranh lap tin hieu trong cung 1 nen)
double   g_peakEquity = 0.0;      // dinh equity cao nhat tu truoc den nay, dung cho Max-DD shutoff
bool     g_ddShutoffTriggered = false;  // khi da kich hoat, KHONG tu reset - can can thiep thu cong (restart EA)

//--- Enum trang thai thi truong
enum MarketRegime
  {
   REGIME_TREND,
   REGIME_RANGE,
   REGIME_UNCLEAR
  };

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   handleADX = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   handleATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   handleTrendMA = iMA(_Symbol, PERIOD_D1, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);

   if(handleADX == INVALID_HANDLE || handleATR == INVALID_HANDLE
      || handleTrendMA == INVALID_HANDLE)
     {
      Print("Loi khoi tao indicator handle. Kiem tra lai.");
      return(INIT_FAILED);
     }

   if(InpUseRatioSignal && !SymbolSelect(InpXAGSymbol, true))
     {
      Print("CANH BAO: Khong tim thay symbol XAG '", InpXAGSymbol,
            "'. Kiem tra ten chinh xac trong Market Watch cua broker. Tat InpUseRatioSignal hoac sua ten.");
     }

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_ddShutoffTriggered = false;

   Print("EA khoi tao thanh cong. Day la KHUNG SUON - can kiem dinh thong ke truoc khi live trade.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleADX);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleTrendMA);
  }

//+------------------------------------------------------------------+
//| Tinh tin hieu XAU/XAG ratio (thay the z-score o nhanh RANGE)      |
//| ratio_change_5 > InpRatioSellThresh  -> want_sell = true          |
//| ratio_change_5 < -InpRatioBuyThresh  -> want_buy  = true          |
//| Neu InpUseRatioGate: chi nhan tin hieu khi ratio_change_20 cung   |
//| dau va |gia tri| > InpRatioGateThresh (xac nhan dang trong xu     |
//| huong phan ky da thiet lap, khong bat spike 5-nen co lap)          |
//+------------------------------------------------------------------+
void CalculateRatioSignal(bool &wantBuy, bool &wantSell)
  {
   wantBuy = false;
   wantSell = false;
   if(!InpUseRatioSignal)
      return;

   int needBars = MathMax(InpRatioChangeBars, InpRatioGateBars) + 1;
   double xauClose[], xagClose[];
   ArraySetAsSeries(xauClose, true);
   ArraySetAsSeries(xagClose, true);
   // shift=1: dung nen da DONG gan nhat, khong dung nen dang hinh thanh (tranh repaint,
   // dong bo voi cach backtest Python da kiem dinh luon dung du lieu nen dong hoan toan)
   if(CopyClose(_Symbol, PERIOD_CURRENT, 1, needBars, xauClose) < needBars)
      return;
   if(CopyClose(InpXAGSymbol, PERIOD_CURRENT, 1, needBars, xagClose) < needBars)
      return; // khong lay duoc gia bac -> khong phat tin hieu (fail-safe, khac voi filter DXY/trend)

   double ratioNow  = xauClose[0] / xagClose[0];
   double ratio5    = xauClose[InpRatioChangeBars] / xagClose[InpRatioChangeBars];
   double ratio20   = xauClose[InpRatioGateBars] / xagClose[InpRatioGateBars];
   if(ratio5 == 0.0 || ratio20 == 0.0)
      return;

   double ratioChange5  = (ratioNow - ratio5) / ratio5;
   double ratioChange20 = (ratioNow - ratio20) / ratio20;

   if(InpUseRatioGate)
     {
      bool sameSign = (ratioChange5 > 0 && ratioChange20 > 0) || (ratioChange5 < 0 && ratioChange20 < 0);
      if(!sameSign || MathAbs(ratioChange20) <= InpRatioGateThresh)
         return; // chua xac nhan dang trong xu huong phan ky da thiet lap -> bo qua tin hieu
     }

   if(ratioChange5 > InpRatioSellThresh)
      wantSell = true;
   else if(ratioChange5 < -InpRatioBuyThresh)
      wantBuy = true;
  }

//+------------------------------------------------------------------+
//| Xac dinh regime thi truong hien tai qua ADX                      |
//+------------------------------------------------------------------+
MarketRegime GetMarketRegime()
  {
   double adxBuffer[];
   ArraySetAsSeries(adxBuffer, true);
   // shift=1: nen da dong gan nhat, khong dung nen dang hinh thanh (dong bo voi Python)
   if(CopyBuffer(handleADX, 0, 1, 1, adxBuffer) <= 0)
      return REGIME_UNCLEAR;

   double adxValue = adxBuffer[0];
   if(adxValue >= InpADXTrendThresh)
      return REGIME_TREND;
   else if(adxValue <= InpADXRangeThresh)
      return REGIME_RANGE;
   else
      return REGIME_UNCLEAR; // vung xam giua 2 nguong -> khong giao dich
  }

//+------------------------------------------------------------------+
//| Tinh Momentum chuan hoa theo ATR                                  |
//+------------------------------------------------------------------+
double CalculateNormalizedMomentum(double &atrValueOut)
  {
   double closePrices[];
   ArraySetAsSeries(closePrices, true);
   // shift=1: nen da dong gan nhat, khong dung nen dang hinh thanh (dong bo voi Python)
   if(CopyClose(_Symbol, PERIOD_CURRENT, 1, InpMomLookback + 1, closePrices) < InpMomLookback + 1)
      return(0.0);

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(handleATR, 0, 1, 1, atrBuffer) <= 0)
      return(0.0);

   atrValueOut = atrBuffer[0];
   if(atrValueOut == 0.0)
      return(0.0);

   double priceChange = closePrices[0] - closePrices[InpMomLookback];
   return priceChange / atrValueOut;
  }

//+------------------------------------------------------------------+
//| Filter xu huong dai han: gia so voi MA50 tren khung NGAY           |
//| Tra ve: 1 = uu tien BUY (gia tren MA50), -1 = uu tien SELL, 0 = loi|
//+------------------------------------------------------------------+
int CheckTrendFilter()
  {
   if(!InpUseTrendFilter)
      return 0; // filter tat -> khong chan gi ca

   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   // Dung shift=1 (nen NGAY da dong gan nhat) de tranh nhin vao nen ngay chua dong (repaint)
   if(CopyBuffer(handleTrendMA, 0, 1, 1, maBuffer) <= 0)
      return 0; // khong lay duoc du lieu -> khong chan (fail-open, giong logic filter khac)

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(currentPrice > maBuffer[0])
      return 1;   // tren MA50 -> uu tien BUY
   else if(currentPrice < maBuffer[0])
      return -1;  // duoi MA50 -> uu tien SELL
   return 0;
  }

//+------------------------------------------------------------------+
//| Filter bien dong dot bien: so sanh ATR hien tai voi ATR trung binh |
//| cua InpVolRefBars nen gan nhat. Tra ve true = dang bien dong bat   |
//| thuong (nen bo qua tin hieu, tranh whipsaw sau cu soc gia)         |
//+------------------------------------------------------------------+
bool IsVolatilitySpike()
  {
   if(!InpUseVolFilter)
      return false;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   // shift=1: nen da dong gan nhat, khong dung nen dang hinh thanh (dong bo voi Python)
   if(CopyBuffer(handleATR, 0, 1, InpVolRefBars, atrBuffer) < InpVolRefBars)
      return false; // chua du du lieu lich su -> khong chan (fail-open)

   double currentATR = atrBuffer[0];
   double sum = 0.0;
   for(int i = 0; i < InpVolRefBars; i++)
      sum += atrBuffer[i];
   double avgATR = sum / InpVolRefBars;

   if(avgATR <= 0)
      return false;

   return (currentATR > InpVolSpikeMultiplier * avgATR);
  }

//+------------------------------------------------------------------+
//| Filter tin tuc: bo qua tin hieu quanh tin USD quan trong (NFP/     |
//| FOMC/CPI...) dung MQL5 Economic Calendar co san (khong can API     |
//| ngoai). Fail-open neu khong lay duoc du lieu calendar.             |
//+------------------------------------------------------------------+
bool IsNewsBlackout()
  {
   if(!InpUseNewsFilter)
      return false;

   datetime now  = TimeCurrent();
   datetime from = now - InpNewsMinutesAfter * 60;
   datetime to   = now + InpNewsMinutesBefore * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, "USD");
   if(n <= 0)
      return false; // khong lay duoc du lieu calendar -> khong chan (fail-open)

   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
         return true; // co tin USD quan trong trong khoang [-after, +before] -> chan
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Max Drawdown auto-shutoff: tinh % sut giam tu dinh equity cao nhat.|
//| Khi vuot nguong, NGUNG MO LENH MOI (lenh dang mo van chay SL/TP    |
//| binh thuong). Mot khi kich hoat, KHONG tu reset - can restart EA   |
//| (tranh vao lai ngay sau 1 cu sut manh khi chua ro nguyen nhan).    |
//+------------------------------------------------------------------+
bool IsMaxDDShutoffActive()
  {
   if(!InpUseMaxDDShutoff)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
      g_peakEquity = equity;

   if(g_ddShutoffTriggered)
      return true;

   if(g_peakEquity <= 0)
      return false;

   double ddPercent = (g_peakEquity - equity) / g_peakEquity * 100.0;
   if(ddPercent >= InpMaxDDPercent)
     {
      g_ddShutoffTriggered = true;
      PrintFormat("CANH BAO: Max Drawdown %.2f%% >= nguong %.2f%%. NGUNG mo lenh moi. " +
                  "Lenh dang mo (neu co) van chay SL/TP binh thuong. Can kiem tra thu cong va restart EA.",
                  ddPercent, InpMaxDDPercent);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Kiem tra da co lenh mo cua EA nay chua                            |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
         && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Tinh lot size theo % risk tai khoan va khoang cach SL              |
//| Cong thuc: risk_tien = Balance * risk% ; lot = risk_tien / (SL_khoang_cach_gia * tick_value_per_lot) |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   if(!InpUseRiskPercent)
      return InpFixedLotSize;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0)
     {
      Print("CANH BAO: Khong lay duoc tick value/size, fallback ve lot co dinh.");
      return InpFixedLotSize;
     }

   // Gia tri tien mat cho 1 lot ung voi khoang cach SL
   double moneyPerLotAtSL = (slDistancePrice / tickSize) * tickValue;
   if(moneyPerLotAtSL <= 0)
      return InpFixedLotSize;

   double rawLot = riskMoney / moneyPerLotAtSL;

   // Lam tron theo buoc lot toi thieu cua broker
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLotBroker = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   rawLot = MathFloor(rawLot / lotStep) * lotStep;
   rawLot = MathMax(rawLot, minLot);
   rawLot = MathMin(rawLot, MathMin(maxLotBroker, InpMaxLotSize));  // tran an toan kep

   return rawLot;
  }

//+------------------------------------------------------------------+
//| Mo lenh (don gian hoa - can bo sung xu ly loi day du khi dung that)|
//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, double atrValue)
  {
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = isBuy ? price - InpATR_SL_Mult * atrValue : price + InpATR_SL_Mult * atrValue;
   double tp = isBuy ? price + InpATR_TP_Mult * atrValue : price - InpATR_TP_Mult * atrValue;

   double slDistance = InpATR_SL_Mult * atrValue;
   double lotSize = CalculateLotSize(slDistance);

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = _Symbol;
   request.volume    = lotSize;
   request.type      = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price     = price;
   request.sl        = NormalizeDouble(sl, _Digits);
   request.tp         = NormalizeDouble(tp, _Digits);
   request.deviation = 20;
   request.magic     = InpMagicNumber;
   request.comment   = "RegimeBot";

   if(!OrderSend(request, result))
      Print("OrderSend that bai. Error: ", GetLastError());
   else
      Print("Da mo lenh ", (isBuy ? "BUY" : "SELL"), " ticket=", result.order,
            " | lot=", lotSize, " | SL_distance=", DoubleToString(slDistance,_Digits));
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- Chi xu ly 1 lan cho moi nen moi (tranh danh gia lai tin hieu nhieu lan trong cung 1 nen) ---
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   // --- TAM THOI: log indicator cua nen da dong gan nhat de doi chieu voi Python ---
   if(InpDebugLog)
     {
      double dbgAdx[], dbgAtr[], dbgClose[];
      ArraySetAsSeries(dbgAdx, true);
      ArraySetAsSeries(dbgAtr, true);
      ArraySetAsSeries(dbgClose, true);
      if(CopyBuffer(handleADX, 0, 1, 1, dbgAdx) > 0 && CopyBuffer(handleATR, 0, 1, 1, dbgAtr) > 0
         && CopyClose(_Symbol, PERIOD_CURRENT, 1, InpMomLookback + 1, dbgClose) >= InpMomLookback + 1)
        {
         double dbgAtrV = dbgAtr[0];
         double dbgMom  = (dbgAtrV > 0) ? (dbgClose[0] - dbgClose[InpMomLookback]) / dbgAtrV : 0.0;
         PrintFormat("DBG %s adx=%.4f atr=%.4f mom=%.4f close=%.3f",
                     TimeToString(iTime(_Symbol, PERIOD_CURRENT, 1), TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                     dbgAdx[0], dbgAtrV, dbgMom, dbgClose[0]);
        }
     }

   // --- Kiem tra spread ---
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
      return;

   // --- Khong vao them lenh moi neu da co vi the mo ---
   if(HasOpenPosition())
      return;

   // --- Max Drawdown auto-shutoff: ngung mo lenh moi neu DD vuot nguong ---
   if(IsMaxDDShutoffActive())
      return;

   // --- Filter tin tuc: bo qua tin hieu quanh tin USD quan trong ---
   if(IsNewsBlackout())
      return;

   // --- Filter bien dong dot bien: bo qua hoan toan neu dang trong cu soc gia ---
   if(IsVolatilitySpike())
      return;

   // --- Buoc 1: xac dinh regime ---
   MarketRegime regime = GetMarketRegime();
   if(regime == REGIME_UNCLEAR)
      return; // vung xam -> khong giao dich

   // --- Buoc 2: tinh tin hieu tuong ung voi regime ---
   double atrValue = 0.0;
   bool wantBuy = false, wantSell = false;

   if(regime == REGIME_TREND)
     {
      double normMomentum = CalculateNormalizedMomentum(atrValue);
      if(normMomentum > InpMomBuyThresh)
         wantBuy = true;
      else if(normMomentum < -InpMomSellThresh)
         wantSell = true;
     }
   else if(regime == REGIME_RANGE)
     {
      // XAU/XAG ratio-reversion: ratio tang manh gan day -> vang "chay nhanh hon" bac ->
      // ky vong dao chieu tuong doi -> SELL. Ratio giam manh -> BUY. Xem canh bao dau file
      // ve tinh phu thuoc regime cua tin hieu nay.
      CalculateRatioSignal(wantBuy, wantSell);

      // Can atrValue de dat SL/TP ngay ca trong nhanh ratio-reversion
      double atrBuffer[];
      ArraySetAsSeries(atrBuffer, true);
      if(CopyBuffer(handleATR, 0, 1, 1, atrBuffer) > 0)
         atrValue = atrBuffer[0];
     }

   if(atrValue <= 0.0)
      return;

   // --- Buoc 3: ap dung filter xu huong dai han MA50-Daily ---
   int trendSignal = CheckTrendFilter();
   bool trendOK_buy  = (trendSignal == 1 || trendSignal == 0);
   bool trendOK_sell = (trendSignal == -1 || trendSignal == 0);

   if(wantBuy && trendOK_buy)
      OpenPosition(true, atrValue);
   else if(wantSell && trendOK_sell)
      OpenPosition(false, atrValue);
  }
//+------------------------------------------------------------------+
