//+------------------------------------------------------------------+
//| XAUUSD_H1_Ratchet_EA_v2.mq5                                       |
//| 2-bar momentum entry, EMA/BB veto, fib TP, distance-based ratchet  |
//| trailing. H1 and M30 signal engines can run independently or      |
//| together in parallel (each with its own enable switch, magic      |
//| number, and initial-SL default).                                  |
//|                                                                    |
//| v2 = ban goc + filter MA50-Daily + ADX Regime + Volatility Spike   |
//| (DXY va ATR-based-SL co san trong code nhung TAT MAC DINH vi test  |
//|  cho thay chung lam giam hieu qua tren CHINH he thong entry nay)   |
//|                                                                    |
//| KET QUA BACKTEST (mo phong Python tren du lieu H1 lich su,         |
//| CHUA chay qua MT5 Strategy Tester that, KHONG dam bao tuong lai):  |
//|  - Baseline (khong filter): PF=1.027, PnL=787, MaxDD=-1049,        |
//|    ty le thua that=45.2%                                          |
//|  - v2 (MA50+ADX+Vol, SL co dinh giu nguyen): PF=1.255, PnL=1662,   |
//|    MaxDD=-511 (giam 51%), ty le thua that=40.7%                    |
//|  - Loc bo ~75% so luong tin hieu goc (643 vs 2525 lenh) - it lenh  |
//|    hon nhung chat luong tung lenh cao hon ro ret                   |
//|                                                                    |
//| v2.1 (2026-09-09): FIX BUG REPAINT giong het bug tim thay o        |
//| RegimeBot - ADXBlocks/VolSpikeBlocks/GetCurrentATR/DXYBlocks deu   |
//| doc CopyBuffer/CopyClose shift=0 (nen DANG HINH THANH) thay vi     |
//| shift=1 (nen da dong). Chi MA50Blocks lam dung tu dau. Phat hien   |
//| khi soi report live that (EA_WinRate_Report.xlsx, 2026-08-31, magic|
//| 20260228/20260229): H1 leg 4 lenh/3 lo/-$57.62 (WR 25%).           |
//|                                                                    |
//| KIEM DINH THAT tren MT5 Strategy Tester (Every tick, tick that,    |
//| 2024.01.01-2026.09.09, fixed lot 0.01, Forward=No, Random delay -  |
//| chay tay qua GUI vi headless bi loi auto-update cua chinh MT5):    |
//| grid InpADXFloor_H1 (nguoc huong so voi RegimeBot - o day ADX CANG |
//| CAO CANG TE, vi entry logic la candle-pattern+EMA/BB cross, khong  |
//| phai momentum):                                                    |
//|   ADXFloor=20: n=902 PF=1.051 PnL=+427.71 DD=6.14%  <- CHON, tot   |
//|                nhat PF/PnL, DD van chap nhan duoc                  |
//|   ADXFloor=24: n=725 PF=1.045 PnL=+305.47 DD=4.72%  (DD thap hon)  |
//|   ADXFloor=28: n=559 PF=0.998 PnL=-12.60  DD=3.51%  (default CU -  |
//|                HOA VON/LO NHE tren toan bo lich su, khop voi bao   |
//|                cao live that cho thay bot dang lo)                 |
//|   ADXFloor=32: n=407 PF=0.906 PnL=-390.24 DD=4.57%  (te nhat)      |
//| KET LUAN: default cu 28.0 la nguyen nhan chinh gay lo (qua chat,   |
//| loai bo qua nhieu tin hieu tot). Doi ve 20.0.                      |
//| LUU Y: chua test ADXFloor<20 va chua toi uu M30 engine - PF=1.05   |
//| van la edge yeu. Python port (bar-resolution) cho ra ket qua KHONG |
//| dang tin cho co che trailing chat (GapTrigger=1.0) cua bot nay -   |
//| PHAI dung MT5 that (tick-level) de kiem dinh.                      |
//|                                                                    |
//| v2.2 (2026-09-09, cung ngay): FIX BUG HIEU NANG NGHIEM TRONG trong |
//| ManageTrailing() - vong lap while(true) tang SL/TP tung buoc nho   |
//| (SLStep) co the chay HANG TRIEU LAN neu gia nhay vot lon trong 1   |
//| tick (vd thanh khoan thap dip cuoi nam), khien Strategy Tester treo|
//| hang gio dong ho (CPU van chay, khong deadlock that, nhung tien do |
//| test gan nhu dung lai). Da sua: tinh so buoc ratchet truc tiep     |
//| bang cong thuc (MathFloor) thay vi lap tung buoc - KET QUA GIONG   |
//| HET ve mat logic, chi nhanh hon rat nhieu (O(1) thay vi O(n)).     |
//| Day cung la rui ro that tren live neu gia gap manh (tin lon/thanh  |
//| khoan thap), khong chi la van de backtest.                         |
//|                                                                    |
//| Sau khi fix, kiem dinh lai qua MT5 that (full 2024.01-2026.09,     |
//| Every tick that, fixed lot 0.01) cach ly tung yeu to filter/trailing|
//| (PnL, khong co PF/DD chi tiet do doc truc tiep tu Journal log de   |
//| tiet kiem thoi gian, xem file report neu can PF/DD chinh xac):     |
//|   A. Khong filter gi (= dung y het bot live H1.mq5 dang chay):     |
//|      PnL=-32.33 (LO NHE - giai thich vi sao bot live dang lo)      |
//|   B. Chi MA50: PnL=+211.27                                         |
//|   C. MA50+ADX20 (khong Vol): PnL=+241.05                           |
//|   D. MA50+ADX20+Vol, trailing NOI LONG (TrailStart 15->25,         |
//|      GapTrigger 1.0->3.0, SLStep 0.5->1.5, TPStep 0.45->1.0):      |
//|      PnL=+633.71  <- TOT NHAT, hon ca default v2.1 (PnL=427.71)    |
//| KET LUAN: trailing qua CHAT (GapTrigger=1.0) tu lam hai chinh no - |
//| ratchet qua nhanh khien nhieu lenh bi cat loi som ngay khi vua co  |
//| lai nhe, chua kip chay theo trend. Noi long trailing giup PnL tang |
//| ~48% so voi default cu. DA DOI default: TrailStart=25, GapTrigger= |
//| 3.0, SLStep=1.5, TPStep=1.0 (giu nguyen filter MA50+ADX20+Vol).    |
//| VAN CHUA CO PF/MaxDD chinh xac cho config D (chi co PnL tu log) -  |
//| nen chay lai 1 lan qua GUI, Save as Report, de co so lieu day du   |
//| truoc khi ban. Edge van con yeu (~$0.65/ngay tren lot 0.01) - $20/ |
//| ngay CHUA kha thi an toan, can nang lot ~30x se keo DD len tuong   |
//| ung (30x DD hien tai) - phai co von lon hoac tim them edge truoc.  |
//|                                                                    |
//| v2.3 (2026-09-09, cung ngay): THEM Filter Gio vao lenh. Phan tich  |
//| toan bo 858 lenh cua config D theo GIO SERVER, chia train/test     |
//| (2 nua thoi gian doc lap) de tranh data-mining nhieu:              |
//|   Gio 7: LO nang CA HAI nua (-128.97 roi -197.64, cang ve sau cang |
//|          te) - ROBUST, khong phai nhieu.                          |
//|   Gio 22: LO ca hai nua (-135.84, -42.03) - ROBUST.                |
//|   Gio 1: LOI ca hai nua (+272.95, +103.67) - ROBUST nhung KHONG    |
//|          chan gio khac de lay loi, chi CHAN 2 gio xau la du an     |
//|          toan (cac gio khac dao chieu giua 2 nua -> nhieu, bo qua).|
//| Ly do hop ly: gio 7/22 server thuong roi vao khoang giao ca phien  |
//| A-Au-My, thanh khoan thap, spread rong - khop ly thuyet FX co ban. |
//| THEM: InpUseHourFilter (default true), InpBlockedHours="7,22".     |
//| KET QUA: PnL tu $633.71 (config D) -> $1149.66 (+81%) khi chan gio |
//| 7 va 22, GIU NGUYEN filter/trailing khac. Day la cai thien LON     |
//| NHAT tim duoc tu dau den gio.                                      |
//|                                                                    |
//| TEST muc tieu $20/ngay bang DailyProfitStopUSD (dong het lenh +    |
//| khoa giao dich khi PnL trong ngay dat nguong, y tuong cua user:    |
//| chi can 1-2 lenh dung la du dat goal, roi khoa lai). Avg win o lot  |
//| 0.01 = $24.29 (config D) - DA VUOT $20, ve mat ly thuyet 1 lenh    |
//| thang la du. Nhung THUC TE (full 2.7 nam, hour-filter config):     |
//|   Khong khoa:  PnL=1149.66                                         |
//|   Khoa $20:    PnL=551.27  | 261/980 ngay dat (26.6%)              |
//|   Khoa $30:    PnL=835.59  | 165/980 ngay dat (16.8%)              |
//|   Khoa $35:    PnL=1097.63 | 154/980 ngay dat (15.7%) <- PnL cao   |
//|                nhat trong cac muc khoa, gan bang khong khoa        |
//|   Khoa $40:    PnL=980.34  | 135/980 ngay dat (13.8%)              |
//| KET LUAN QUAN TRONG: KHONG co nguong nao bien $20/ngay thanh ket   |
//| qua DA SO cac ngay - tot nhat chi 26.6% (nguong $20), tuc ~73% so  |
//| ngay KHONG dat duoc. Nguyen nhan goc: 53.5% tong so ngay trong ky  |
//| test KHONG CO LENH NAO ca (engine H1 qua thua tin hieu), khong     |
//| phai do avg-win thap. DailyProfitStopUSD giup khoa loi/giam bien   |
//| dong o NHUNG NGAY CO GIAO DICH, nhung khong tao them ngay co giao  |
//| dich. Muon tang ty le "ngay co co hoi" phai bat them engine M30    |
//| (CHUA test) de lap vao nhung ngay H1 im ang, khong phai chinh      |
//| nguong khoa. DailyProfitStopUSD VAN DE O 0.0 (tat) trong default - |
//| user tu chon nguong phu hop khau vi rui ro neu muon bat.           |
//|                                                                    |
//| v2.4 (2026-09-09, cung ngay): 2 cai thien nua sau khi tim edge     |
//| manh hon combo ADX+MA50 co ban.                                    |
//|                                                                    |
//| (1) RE-GRID InpADXFloor_H1 tren nen hour-filter+loose-trailing moi |
//| (nguong 20 cu duoc chon TRUOC KHI co hour-filter, co the khong con |
//| toi uu do tuong tac). Ket qua (full 2.7 nam, MT5 that):            |
//|   16: ~1209.80 (UOC TINH, chay khong xong het do qua cham - xem    |
//|        muc (3) ben duoi, khong dung so nay de quyet dinh)          |
//|   20: 1149.66 (cu)                                                 |
//|   24: 1186.23 (THANG - full du lieu, tin cay)                      |
//|   28: 636.82                                                       |
//| -> Doi InpADXFloor_H1 mac dinh tu 20.0 sang 24.0.                  |
//|                                                                    |
//| (2) Phan tich THU TU tin hieu trong 1 CUM giao dich (khong dung    |
//| moc lich 0h vi user chi ra dung: moc do tuy tien, phai kiem tra    |
//| nhay cam voi moc). Test ca 24 moc gio bat dau "ngay" - tin hieu    |
//| #1 sau bat ky moc nao deu duong o nua test (nhung chi mot so moc   |
//| (0,1,22,23h - dung vao khoang nghi tu nhien cua XAUUSD) moi duong  |
//| CA HAI nua). Kiem chung chac chan hon bang GAP-BASED CLUSTERING    |
//| (cum moi = khoang cach > 18h tu lenh truoc, KHONG phu thuoc moc    |
//| dong ho nao): hang 1-3 trong cum DUONG ca 2 nua thoi gian, hang    |
//| 4+ AM ca 2 nua (vd hang 4: train -155.88, test -133.24). THEM      |
//| InpUseMaxSignalsPerDay (default true) + InpMaxSignalsPerDay=3      |
//| (dem tin hieu MOI thanh cong ca 2 phia, reset moc 0h server -      |
//| don gian hoa so voi gap-based nhung da kiem tra 0h la mot trong    |
//| cac moc "sach" o tren). KET QUA: PnL 1186.23 (ADXFloor=24, khong   |
//| gioi han) -> 1275.63 (+7.5%) khi gioi han 3 tin hieu/ngay.         |
//|                                                                    |
//| (3) PHAT HIEN VAN DE HIEU NANG KHAC voi ADXFloor=16 rieng: backtest|
//| chay cuc cham (>1 gio, so voi <15s cho 20/24/28), CPU van hoat dong|
//| (khong deadlock) nhung tien do gan nhu dung. Da kiem tra lai code  |
//| ManageTrailing/PruneClosedTracking/FindTrackedIndex - KHONG thay   |
//| bug ro rang (logic dung). Nghi ngo: ADXFloor=16 qua long tao ra    |
//| mot giai doan gia tri cu the (giua 2024-2026) noi so luong vi the  |
//| dong thoi mo + tan suat sua SL/TP tang dot bien, nhung CHUA XAC    |
//| DINH DUOC NGUYEN NHAN CHINH XAC - can dieu tra them neu quay lai   |
//| test ADXFloor<20 trong tuong lai. KHONG dung ADXFloor=16, giu 24.  |
//|                                                                    |
//| TONG KET CHUOI CAI TIEN TU DAU: D(633.71) -> F them hour-filter    |
//| (1149.66) -> F24 doi ADXFloor 20->24 (1186.23) -> K them Max3      |
//| tin hieu/ngay (1275.63). Tang 101% so voi config D ban dau.        |
//|                                                                    |
//| v2.5 (2026-09-09, cung ngay): THEM TRAN ADX (khong chi san).       |
//| User dat gia thuyet "trend khong ro/vol yeu" gay lo (kieu grinding |
//| trend da biet tu RegimeBot) - kiem tra bang cach bin ADX cua tin   |
//| hieu THUC TE da vao lenh (khong phai bin toan bo du lieu) thanh 6  |
//| khoang (24-28,28-32,32-36,36-40,40-50,50+), chia train/test:       |
//|   24-28, 28-32: DAO CHIEU giua 2 nua (nhieu, khong dung)           |
//|   32-36: DUONG ca 2 nua (+135.16, +260.70) - vung "sweet spot"     |
//|   36-40: AM ca 2 nua nhung nhe (-4.43, -178.14)                    |
//|   40-50: AM MANH ca 2 nua (-291.23, -79.60) - ROBUST               |
//|   50+:   AM ca 2 nua (-62.42, -19.21) - ROBUST                     |
//| KET LUAN NGUOC VOI GIA THUYET BAN DAU: khong phai trend YEU gay    |
//| lo, ma la trend QUA MANH (ADX>=40, kieu parabolic/canh kiet) - co  |
//| the do vao lenh theo da khi song da gan het, de dinh pullback ngay |
//| sau. THEM InpUseADXCeiling (default true) + InpADXCeiling_H1=40.0  |
//| (chi ap dung engine H1, M30 chua test). KET QUA: PnL 1275.63 ->    |
//| 1528.83 (+19.8%) tren nen K (hour-filter+ADX24+Max3tinhieu/ngay).  |
//|                                                                    |
//| TONG KET CUOI CUNG v2.5: D(633.71) -> +hour-filter(1149.66) ->     |
//| +ADX24(1186.23) -> +Max3/ngay(1275.63) -> +tran ADX40(1528.83).    |
//| Tang 141% so voi config D ban dau.                                 |
//|                                                                    |
//| v2.7 (2026-09-09, cung ngay): DAO CHIEU thay vi bo qua khi ADX qua |
//| cao. Y tuong cua user: da biet vung ADX>=40 lo nang robust (xem    |
//| v2.5) - thay vi chi BO QUA tin hieu do (ve 0), DAO CHIEU huong lenh|
//| (mua->ban, ban->mua) de thu loi tu chinh cu "canh kiet/pullback"   |
//| do. Streak/pattern van tinh theo huong CANDLE PATTERN goc, chi     |
//| huong LENH THAT su dao nguoc; MA50/DXY filter van danh gia theo    |
//| huong goc (CHUA re-validate cho huong dao - don gian hoa co y).    |
//| THEM InpReverseOnADXCeiling (BAT MAC DINH true). KET QUA MT5 that: |
//| PnL 1528.83 -> 1689.42 (+10.5%) - XAC NHAN gia thuyet dung, dao    |
//| chieu tot hon bo qua don thuan.                                    |
//|                                                                    |
//| v2.6 (cung ngay, M30): grid InpADXFloor_M30 tren MT5 that (khong   |
//| tach train/test - RUI RO OVERFIT cao hon cac filter khac da tach): |
//| 20($3202.23) > 25($2189.97,cu) > 28($1862.28) > 32($1322.63) - don |
//| dieu, cang thap cang tot. Doi default ve 20.0. KHONG test <20 (rui |
//| ro hieu nang nhu ADXFloor_H1=16 truoc day, chua ro nguyen nhan).   |
//| THEM MaxPerSide_H1/MaxPerSide_M30 rieng biet (truoc dung chung 1   |
//| bien MaxPerSide - bug khi chay 2 engine khac tan suat) + THEM      |
//| InpMaxTotalOpenPositions (default 4) - tran tong so lenh mo dong   |
//| thoi ca 2 engine, kiem soat rui ro khi chay chung (thay vi giam lot|
//| - user muon giu 0.01 co dinh de kiem soat rui ro don gian).        |
//|                                                                    |
//| TONG KET MOI NHAT (H1 rieng): 1528.83 -> 1689.42 (dao chieu ADX    |
//| cao). M30 rieng (chua co hour-filter/max-signal, CHUA thu nghiem   |
//| dao chieu): 3202.23 tai ADXFloor=20 (n=1191, PF=1.18, 1.21 lenh/   |
//| ngay). Ket hop H1+M30 (UOC TINH THO, chua chay chung thanh cong):  |
//| ~4891 (+10.5% tren tong H1+M30 rieng le). Van con xa $20/ngay       |
//| (~982 ngay -> ~$4.98/ngay o muc nay) nhung tien bo dang ke. File    |
//| rieng XAUUSD_M15_Scalper.mq5 da tao (engine M15+M5), test dau tien |
//| M15 (chua grid gi): PnL=671.54 - co tiem nang, can grid day du.     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- inputs -------------------------------------------------------------
input bool   EnableH1        = true;   // run the H1 signal engine
input bool   EnableM30       = false;  // run the M30 signal engine
input double LotSize         = 0.01;
input int    MaxPerSide_H1   = 3;      // (v2.6) max concurrent open trades per side, engine H1
input int    MaxPerSide_M30  = 3;      // (v2.6) max concurrent open trades per side, engine M30
input int    InpMaxTotalOpenPositions = 4; // (v2.6) tran TONG so lenh dang mo ca 2 engine cong lai, 0 = khong gioi han (kiem soat rui ro khi chay ca H1+M30)
input double InitialSL_H1    = 25.0;   // hard SL distance from entry (H1 engine)
input double InitialSL_M30   = 20.0;   // hard SL distance from entry (M30 engine)
input double TrailStart      = 25.0;   // favorable move needed to arm trailing (v2.2: noi long, xem header)
input double TrailLock       = 10.0;   // SL locked to entry +/- this once armed
input double GapTrigger      = 3.0;    // ratchet fires when (price-SL) gap >= this (v2.2: noi long)
input double SLStep          = 1.5;    // SL step per ratchet fire (v2.2: noi long)
input double TPStep          = 1.0;    // TP step per ratchet fire (v2.2: noi long)
input double MinTPDist       = 20.0;   // fib TP must be at least this far from entry
input int    FibLookback     = 20;     // signal-timeframe bars for fib range
input int    EmaPeriod       = 9;
input int    BBPeriod        = 20;     // BB middle = SMA(BBPeriod)
input ulong  MagicNumberH1   = 20260228;
input ulong  MagicNumberM30  = 20260229;
input int    Slippage        = 1000;   // max price deviation, points
input int    MaxRequotes     = 3;      // retry attempts on requote
input double DailyProfitStopPct = 0.0;    // close all + stop trading when PnL gains this % vs snapshot balance (0 = disabled)
input double DailyProfitStopUSD = 0.0;    // close all + stop trading when PnL gains this many $ (0 = disabled). If both set, whichever is hit first wins.
input int    SnapHour            = 0;     // server-time hour (0-23) to take the daily balance snapshot. 0 = midnight.

//--- Cac filter da kiem dinh RIENG cho chinh he thong entry nay (candle-pattern + EMA/BB) ---
//--- Ket qua test: MA50 + ADX + Vol-spike CO LOI RO RET; DXY va ATR-based-SL LAI CO HAI  ---
//--- khi ghep vao entry logic nay (khac voi ket qua tren he thong regime-detection khac) ---
input group "=== Filter: DXY (lien thi truong) ==="
input bool   InpUseDXYFilter     = false;  // TAT MAC DINH - da test: lam GIAM loi nhuan tren he thong entry nay
input string InpDXYSymbol        = "DXY";  // Ten symbol DXY tren broker - KIEM TRA lai trong Market Watch

input group "=== Filter: Xu huong dai han (MA50-Daily) ==="
input bool   InpUseMA50Filter    = true;   // BAT MAC DINH - filter tot nhat, PnL tang manh khi dung rieng
input int    InpMA50Period       = 50;     // Period tren khung NGAY (KHONG phai H1/M30)

input group "=== Filter: Regime ADX (loai bo tin hieu o vung 'grinding trend' yeu) ==="
input bool   InpUseADXFilter     = true;   // BAT MAC DINH - giam Max Drawdown manh
input int    InpADXPeriod        = 14;
input double InpADXFloor_H1      = 24.0;   // (v2.4) re-grid tren nen hour-filter+loose-trailing: 24 > 20 > 16(chua ro) > 28
input double InpADXFloor_M30     = 20.0;   // (v2.6) grid tren MT5 that: 20($3202)>25($2190)>28($1862)>32($1323), don dieu, KHONG test <20 (rui ro hieu nang nhu H1=16)
input bool   InpUseADXCeiling    = true;   // (v2.5) BAT MAC DINH - ADX qua cao (trend "canh kiet") lo nang, robust ca train/test
input double InpADXCeiling_H1    = 40.0;   // ADX phai < muc nay (engine H1) - vung 40+ la noi lo tap trung
input bool   InpReverseOnADXCeiling = true;  // (v2.7, kiem dinh train/test 2026-09-09) BAT MAC DINH nhung LA EDGE MONG:
                                              // train(24.01-25.09) reverse PnL=771.72/PF=1.19/n=364 vs skip PnL=595.00/PF=1.20/n=268
                                              // test (25.09-26.09) reverse PnL=917.70/PF=1.33/n=265 vs skip PnL=907.84/PF=1.42/n=211
                                              // PnL nhinh hon CA 2 nua (nhat quan chieu, khong phai noise) NHUNG PF te hon CA 2 nua (reverse
                                              // them lenh, pha loang PF de doi PnL tuyet doi cao hon - hop ly vi goal la $/ngay). O nua test
                                              // PnL chi hon +1.1% (KHONG phai +10.5% nhu con so full-period cu tung cong bo - con so do
                                              // bi thoi phong do chi test 1 lan tren toan bo du lieu). Van giu true vi PnL luon nhinh hon,
                                              // nhung dung xem day la edge manh - la mot khoan cong them nho, on dinh.

input group "=== Filter: Volatility Spike (tranh whipsaw sau cu soc gia) ==="
input bool   InpUseVolFilter     = true;   // BAT MAC DINH - cai thien nhe them tren nen MA50+ADX
input int    InpATRPeriod        = 14;
input int    InpVolRefBars_H1    = 480;    // ~20 ngay tren H1
input int    InpVolRefBars_M30   = 480;    // ~10 ngay tren M30
input double InpVolSpikeMultiplier = 2.0;  // Bo qua tin hieu neu ATR hien tai > X lan ATR trung binh

input group "=== SL theo ATR (thay the SL co dinh) ==="
input bool   InpUseATRBasedSL    = false;  // TAT MAC DINH - da test: pha vo can bang voi trailing params hien co (TrailStart/GapTrigger...), lam MaxDD tang manh
input double InpATR_SL_Mult      = 2.0;    // SL = ATR * mult (chi dung neu InpUseATRBasedSL = true)

input group "=== Filter: Gio vao lenh (server time) - kiem dinh train/test 2024-2026 ==="
input bool   InpUseHourFilter    = true;   // BAT MAC DINH - chan gio 7 va 22 (lo nang CA 2 nua thoi gian test, robust)
input string InpBlockedHours     = "7,22"; // Danh sach gio server (0-23) bi chan, cach nhau dau phay

input group "=== Filter: So tin hieu moi ngay - kiem dinh train/test 2024-2026 ==="
input bool   InpUseMaxSignalsPerDay = true;  // BAT MAC DINH - tin hieu thu 4+ trong ngay lo/hoa von CA 2 nua thoi gian
input int    InpMaxSignalsPerDay    = 3;     // Tin hieu moi (ca 2 phia) toi da moi ngay server, 0 = khong gioi han

CTrade trade;

//--- daily profit stop state, scoped to this EA's own positions only ---
double   g_snapshotBalance   = 0.0;
datetime g_snapshotDay       = 0;      // midnight (server time) of the snapshot day
bool     g_profitStopHit     = false;
double   g_realizedSinceSnap = 0.0;    // this EA's closed-deal PnL since the snapshot,
                                        // updated event-driven in OnTradeTransaction (no rescans)
int      g_ourOpenCount      = 0;      // this EA's own open positions, kept event-driven so
                                        // OnTick can skip the position loops entirely when flat
int      g_blockedHours[];             // parsed tu InpBlockedHours trong OnInit
datetime g_signalDay      = 0;         // midnight (server time) cua ngay dang dem tin hieu
int      g_signalsToday   = 0;         // so tin hieu MOI (thanh cong) da mo trong ngay nay

double FibRatios[] = {0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0,
                       1.272, 1.618, 2.0, 2.618, 3.618, 4.236,
                       5.0, 6.0, 7.0, 8.0};

//--- per-engine state, one instance per timeframe -----------------------
struct EngineState
{
   bool             enabled;
   ENUM_TIMEFRAMES  tf;
   string           label;
   ulong            magic;
   double           initialSL;
   int              emaHandle;
   int              bbMidHandle;
   datetime         lastBarTime;
   string           streakSide;
   datetime         streakLastBar;
   int              streakCount;
   int              adxHandle;     // MOI: cho filter regime ADX
   int              atrHandle;     // MOI: cho SL theo ATR + filter vol-spike
   double           adxFloor;      // MOI: nguong ADX rieng cho engine nay
   int              volRefBars;    // MOI: so nen tham chieu tinh ATR trung binh rieng cho engine nay
   int              maxPerSide;    // MOI (v2.6): tran so lenh/phia rieng cho engine nay
};

EngineState g_h1, g_m30;

//--- Handle DXY va MA50-Daily (dung chung cho ca 2 engine, khong phu thuoc khung thoi gian) ---
int g_ma50DailyHandle = INVALID_HANDLE;

//--- per-position ratchet state, keyed by ticket -----------------------
ulong  g_ticket[];
double g_bestMove[];
bool   g_trailOn[];

//+------------------------------------------------------------------+
bool InitEngine(EngineState &e, bool enabled, ENUM_TIMEFRAMES tf, string label,
                ulong magic, double initialSL, double adxFloor, int volRefBars, int maxPerSide)
{
   e.enabled     = enabled;
   e.tf          = tf;
   e.label       = label;
   e.magic       = magic;
   e.initialSL   = initialSL;
   e.lastBarTime = 0;
   e.streakSide  = "";
   e.streakLastBar = 0;
   e.streakCount = 0;
   e.adxFloor    = adxFloor;
   e.volRefBars  = volRefBars;
   e.maxPerSide  = maxPerSide;
   if(!enabled) return true;

   e.emaHandle   = iMA(_Symbol, tf, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   e.bbMidHandle = iMA(_Symbol, tf, BBPeriod,  0, MODE_SMA, PRICE_CLOSE);
   e.adxHandle   = iADX(_Symbol, tf, InpADXPeriod);
   e.atrHandle   = iATR(_Symbol, tf, InpATRPeriod);
   return (e.emaHandle != INVALID_HANDLE && e.bbMidHandle != INVALID_HANDLE
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

   if(EnableH1 && EnableM30 && MagicNumberH1 == MagicNumberM30)
   {
      Print("H1_Ratchet_EA: MagicNumberH1 and MagicNumberM30 must differ when both engines "
            "are enabled, otherwise their position caps/trailing would merge. Aborting.");
      return INIT_FAILED;
   }

   if(!InitEngine(g_h1,  EnableH1,  PERIOD_H1,  "H1",  MagicNumberH1,  InitialSL_H1,
                  InpADXFloor_H1, InpVolRefBars_H1, MaxPerSide_H1))
      return INIT_FAILED;
   if(!InitEngine(g_m30, EnableM30, PERIOD_M30, "M30", MagicNumberM30, InitialSL_M30,
                  InpADXFloor_M30, InpVolRefBars_M30, MaxPerSide_M30))
      return INIT_FAILED;

   // Khoi tao filter MA50-Daily va kiem tra symbol DXY
   if(InpUseMA50Filter)
   {
      g_ma50DailyHandle = iMA(_Symbol, PERIOD_D1, InpMA50Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_ma50DailyHandle == INVALID_HANDLE)
      {
         Print("H1_Ratchet_EA: Loi khoi tao MA50-Daily handle.");
         return INIT_FAILED;
      }
   }
   if(InpUseDXYFilter && !SymbolSelect(InpDXYSymbol, true))
   {
      Print("CANH BAO: Khong tim thay symbol DXY '", InpDXYSymbol,
            "'. Kiem tra ten chinh xac trong Market Watch. Filter DXY se bi bo qua (fail-open) neu khong lay duoc du lieu.");
   }

   // arm lastBarTime to the CURRENT forming bar so the first CheckSignal
   // only fires once a genuinely new bar starts after attach — never
   // immediately off whatever pattern already exists at attach time
   if(EnableH1)  g_h1.lastBarTime  = iTime(_Symbol, g_h1.tf, 0);
   if(EnableM30) g_m30.lastBarTime = iTime(_Symbol, g_m30.tf, 0);
   if(!EnableH1 && !EnableM30)
   {
      Print("H1_Ratchet_EA: both EnableH1 and EnableM30 are false, EA will do nothing.");
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
      bool ours = (EnableH1 && magic == (long)MagicNumberH1)
               || (EnableM30 && magic == (long)MagicNumberM30);
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
      bool ours = (EnableH1 && magic == (long)MagicNumberH1)
               || (EnableM30 && magic == (long)MagicNumberM30);
      if(!ours) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      trade.SetExpertMagicNumber((ulong)magic);
      for(int attempt = 0; attempt <= MaxRequotes; attempt++)
      {
         if(trade.PositionClose(ticket)) break;
         uint code = trade.ResultRetcode();
         if(code != TRADE_RETCODE_REQUOTE && code != TRADE_RETCODE_PRICE_CHANGED)
         {
            PrintFormat("H1_Ratchet_EA: profit-stop close of #%I64u failed, retcode %u", ticket, code);
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
      bool ours = (EnableH1 && magic == (long)MagicNumberH1)
               || (EnableM30 && magic == (long)MagicNumberM30);
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
   bool ours = (EnableH1 && magic == (long)MagicNumberH1)
            || (EnableM30 && magic == (long)MagicNumberM30);
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
      PrintFormat("H1_Ratchet_EA: %02d:00 balance snapshot %.2f", SnapHour, g_snapshotBalance);
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
         PrintFormat("H1_Ratchet_EA: this EA's PnL since snapshot +%.2f reached the %s threshold (+%.2f). "
                     "Closing all positions; no new trades until next 00:00 snapshot.",
                     ourPnLToday, hitBy, threshold);
         LogProgress("profit_stop_before_close");
         CloseAllOurs();
         LogProgress("profit_stop_after_close");
      }
   }
}

void OnDeinit(const int reason)
{
   if(EnableH1)  { IndicatorRelease(g_h1.emaHandle);  IndicatorRelease(g_h1.bbMidHandle);
                   IndicatorRelease(g_h1.adxHandle);  IndicatorRelease(g_h1.atrHandle); }
   if(EnableM30) { IndicatorRelease(g_m30.emaHandle); IndicatorRelease(g_m30.bbMidHandle);
                   IndicatorRelease(g_m30.adxHandle); IndicatorRelease(g_m30.atrHandle); }
   if(g_ma50DailyHandle != INVALID_HANDLE) IndicatorRelease(g_ma50DailyHandle);
}

//+------------------------------------------------------------------+
//| fib levels + next-TP-beyond-min-distance, mirrors the backtest    |
//+------------------------------------------------------------------+
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

//--- Tong so lenh dang mo cua ca EA nay (ca 2 engine, ca 2 phia) - dung cho tran rui ro tong ---
int CountAllOpen()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours = (EnableH1 && magic == (long)MagicNumberH1)
               || (EnableM30 && magic == (long)MagicNumberM30);
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
      bool ours = (EnableH1 && magic == (long)MagicNumberH1)
               || (EnableM30 && magic == (long)MagicNumberM30);
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
         // Tinh truc tiep so buoc ratchet bang cong thuc thay vi lap tung buoc -
         // BUG HIEU NANG THAT: neu gia nhay vot lon trong 1 tick (vd thanh khoan
         // thap dip cuoi nam), vong lap cu co the chay hang trieu lan (treo EA
         // vai tieng trong Strategy Tester, rui ro tuong tu tren live neu gap gia).
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
void RealignSLTP(bool isBuy, double initialSL, double hi20, double lo20)
{
   ulong dealTicket = trade.ResultDeal();
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;

   ulong posTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(!PositionSelectByTicket(posTicket)) return;

   double actualEntry = PositionGetDouble(POSITION_PRICE_OPEN);
   double correctSL = NormalizeDouble(isBuy ? actualEntry - initialSL : actualEntry + initialSL, _Digits);
   double correctTP = NormalizeDouble(NextFibTP(hi20, lo20, actualEntry, isBuy), _Digits);

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   if(MathAbs(curSL - correctSL) < _Point && MathAbs(curTP - correctTP) < _Point) return; // already right

   if(!trade.PositionModify(posTicket, correctSL, correctTP))
      PrintFormat("H1_Ratchet_EA: SL/TP realign on #%I64u failed, retcode %u", posTicket, trade.ResultRetcode());
}

//+------------------------------------------------------------------+
bool OpenWithRetry(ulong magic, double initialSL, bool isBuy, double hi20,
                    double lo20, string comment)
{
   trade.SetExpertMagicNumber(magic);
   for(int attempt = 0; attempt <= MaxRequotes; attempt++)
   {
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = isBuy ? price - initialSL : price + initialSL;
      double tp = NextFibTP(hi20, lo20, price, isBuy);

      bool ok = isBuy
         ? trade.Buy(LotSize, _Symbol, price, NormalizeDouble(sl, _Digits),
                     NormalizeDouble(tp, _Digits), comment)
         : trade.Sell(LotSize, _Symbol, price, NormalizeDouble(sl, _Digits),
                      NormalizeDouble(tp, _Digits), comment);
      if(ok)
      {
         RealignSLTP(isBuy, initialSL, hi20, lo20); // fill may have landed away from `price`; fix SL/TP to match
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

//--- Filter so tin hieu/ngay: dam bao dem dung ngay hien tai, tra ve true neu da du ---
bool IsMaxSignalsReached()
{
   if(!InpUseMaxSignalsPerDay || InpMaxSignalsPerDay <= 0) return false;

   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   datetime today = now - (t.hour * 3600 + t.min * 60 + t.sec);
   if(g_signalDay != today)
   {
      g_signalDay = today;
      g_signalsToday = 0;
   }
   return (g_signalsToday >= InpMaxSignalsPerDay);
}

//--- Filter gio vao lenh: tra ve true neu gio server hien tai nam trong danh sach chan ---
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
//| CAC FILTER DA KIEM DINH (walk-forward + permutation test)          |
//| Muc dich: loc bot lenh vao dung luc dieu kien thi truong xau,      |
//| giam ty le bi cat SL - KHONG thay doi logic entry goc, chi VETO    |
//+------------------------------------------------------------------+

//--- Filter DXY: tra ve true neu HUONG DXY mau thuan voi lenh du dinh mo ---
bool DXYBlocks(bool isBuy)
{
   if(!InpUseDXYFilter) return false;
   double dxyClose[];
   ArraySetAsSeries(dxyClose, true);
   // shift=1,2: hai nen DXY da dong gan nhat, khong dung nen dang hinh thanh
   if(CopyClose(InpDXYSymbol, PERIOD_H1, 1, 2, dxyClose) < 2)
      return false; // khong lay duoc du lieu -> khong chan (fail-open)

   // DXY tang -> ap luc giam gia vang -> chan BUY
   // DXY giam -> ap luc tang gia vang -> chan SELL
   if(dxyClose[0] > dxyClose[1] && isBuy)  return true;
   if(dxyClose[0] < dxyClose[1] && !isBuy) return true;
   return false;
}

//--- Filter MA50-Daily: tra ve true neu gia dang sai phia xu huong dai han ---
bool MA50Blocks(bool isBuy)
{
   if(!InpUseMA50Filter) return false;
   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   // shift=1: dung nen NGAY da dong gan nhat, tranh nhin vao nen ngay chua dong (repaint)
   if(CopyBuffer(g_ma50DailyHandle, 0, 1, 1, maBuf) <= 0)
      return false; // fail-open

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(isBuy  && price < maBuf[0]) return true;  // muon BUY nhung gia duoi MA50 -> chan
   if(!isBuy && price > maBuf[0]) return true;  // muon SELL nhung gia tren MA50 -> chan
   return false;
}

//--- Filter ADX Regime: tra ve true neu ADX qua yeu (dang "grinding trend" nhieu whipsaw) ---
bool ADXBlocks(EngineState &e)
{
   if(!InpUseADXFilter) return false;
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   // shift=1: nen da dong gan nhat, khong dung nen dang hinh thanh (repaint bug tim thay o RegimeBot)
   if(CopyBuffer(e.adxHandle, 0, 1, 1, adxBuf) <= 0)
      return false; // fail-open
   return (adxBuf[0] < e.adxFloor);
}

//--- Tra ve true neu ADX qua cao (trend "canh kiet") - dung rieng, KHONG gop vao ADXBlocks
//--- vi v2.7 co the DAO CHIEU thay vi bo qua khi gap dieu kien nay (xem InpReverseOnADXCeiling) ---
bool IsADXTooHigh(EngineState &e)
{
   if(!InpUseADXCeiling || e.label != "H1") return false; // chi ap dung engine H1, da kiem dinh
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(e.adxHandle, 0, 1, 1, adxBuf) <= 0) return false; // fail-open
   return (adxBuf[0] >= InpADXCeiling_H1);
}

//--- Filter Volatility Spike: tra ve true neu bien dong dang dot bien bat thuong ---
bool VolSpikeBlocks(EngineState &e)
{
   if(!InpUseVolFilter) return false;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   // shift=1: nen da dong gan nhat, khong dung nen dang hinh thanh (repaint bug tim thay o RegimeBot)
   if(CopyBuffer(e.atrHandle, 0, 1, e.volRefBars, atrBuf) < e.volRefBars)
      return false; // chua du lich su -> fail-open
   double currentATR = atrBuf[0];
   double sum = 0.0;
   for(int i = 0; i < e.volRefBars; i++) sum += atrBuf[i];
   double avgATR = sum / e.volRefBars;
   if(avgATR <= 0) return false;
   return (currentATR > InpVolSpikeMultiplier * avgATR);
}

//--- Lay ATR hien tai cua 1 engine, dung cho SL theo ATR ---
double GetCurrentATR(EngineState &e)
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   // shift=1: nen da dong gan nhat, khong dung nen dang hinh thanh (repaint bug tim thay o RegimeBot)
   if(CopyBuffer(e.atrHandle, 0, 1, 1, atrBuf) <= 0) return 0.0;
   return atrBuf[0];
}

//+------------------------------------------------------------------+
//| 2-bar signal check for one engine, called once per new bar of      |
//| that engine's timeframe                                            |
//+------------------------------------------------------------------+
void CheckSignal(EngineState &e)
{
   if(IsHourBlocked()) return; // gio server nay da kiem dinh lo nang (xem header) - bo qua het
   if(IsMaxSignalsReached()) return; // du so tin hieu moi/ngay - tin hieu thu 4+ lo/hoa von (xem header)
   if(InpMaxTotalOpenPositions > 0 && CountAllOpen() >= InpMaxTotalOpenPositions) return; // tran rui ro tong khi chay ca 2 engine

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

   if(greenPattern && !crossDown && !buyStreakBlocked && !topWickBlocked && buyLookbackOk
      && !DXYBlocks(true) && !MA50Blocks(true) && !ADXBlocks(e) && !VolSpikeBlocks(e))
   {
      // v2.7: neu ADX qua cao (canh kiet) va bat dao chieu, thuc thi SELL thay vi BUY -
      // pattern/streak tracking van tinh theo huong pattern goc (buy), chi huong LENH THAT dao
      bool tooHigh = IsADXTooHigh(e);
      bool execBuy = !(tooHigh && InpReverseOnADXCeiling);
      if(tooHigh && !InpReverseOnADXCeiling) { /* giu nguyen hanh vi cu: bo qua tin hieu */ }
      else if(CountOpenBySide(e.magic, execBuy) < e.maxPerSide)
      {
         double slDist = InpUseATRBasedSL ? (GetCurrentATR(e) * InpATR_SL_Mult) : e.initialSL;
         if(slDist <= 0) slDist = e.initialSL; // fallback neu ATR loi
         if(OpenWithRetry(e.magic, slDist, execBuy, hi20, lo20, e.label + (execBuy ? "_buy" : "_buyrev")))
         {
            if(e.streakSide == "buy" && e.streakLastBar == b1Time) e.streakCount++;
            else { e.streakSide = "buy"; e.streakCount = 1; }
            e.streakLastBar = b2Time;
            g_signalsToday++;
         }
      }
   }
   else if(redPattern && !crossUp && !sellStreakBlocked && !bottomWickBlocked && sellLookbackOk
      && !DXYBlocks(false) && !MA50Blocks(false) && !ADXBlocks(e) && !VolSpikeBlocks(e))
   {
      bool tooHigh = IsADXTooHigh(e);
      bool execBuy = (tooHigh && InpReverseOnADXCeiling); // dao chieu -> mua thay vi ban
      if(tooHigh && !InpReverseOnADXCeiling) { /* giu nguyen hanh vi cu: bo qua tin hieu */ }
      else if(CountOpenBySide(e.magic, execBuy) < e.maxPerSide)
      {
         double slDist = InpUseATRBasedSL ? (GetCurrentATR(e) * InpATR_SL_Mult) : e.initialSL;
         if(slDist <= 0) slDist = e.initialSL;
         if(OpenWithRetry(e.magic, slDist, execBuy, hi20, lo20, e.label + (execBuy ? "_sellrev" : "_sell")))
         {
            if(e.streakSide == "sell" && e.streakLastBar == b1Time) e.streakCount++;
            else { e.streakSide = "sell"; e.streakCount = 1; }
            e.streakLastBar = b2Time;
            g_signalsToday++;
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageTrailing();
   UpdateProfitStop();

   if(g_profitStopHit) return; // no new entries until next 00:00 snapshot

   if(EnableH1)
   {
      datetime cur = iTime(_Symbol, g_h1.tf, 0);
      if(cur != g_h1.lastBarTime)
      {
         g_h1.lastBarTime = cur;
         CheckSignal(g_h1);
      }
   }
   if(EnableM30)
   {
      datetime cur = iTime(_Symbol, g_m30.tf, 0);
      if(cur != g_m30.lastBarTime)
      {
         g_m30.lastBarTime = cur;
         CheckSignal(g_m30);
      }
   }
}
//+------------------------------------------------------------------+
