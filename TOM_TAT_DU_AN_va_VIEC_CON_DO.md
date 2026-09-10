# Tóm tắt dự án: Bot Trading XAUUSD — Trạng thái hiện tại

## Mục tiêu
Xây bot trading XAU/USD (vàng) để bán ra thị trường, dùng phương pháp kiểm định thống kê
nghiêm ngặt (theo cuốn "Statistically Sound Indicators" — Timothy Masters): walk-forward
optimization + Monte Carlo permutation test cho mọi quyết định tham số/filter.

## Các file .mq5 đã hoàn thành (trong outputs)
- `XAUUSD_RegimeBot_v4.mq5` — bot H1 chính thức: ADX regime (28/15) + momentum + DXY filter +
  MA50-Daily trend filter + Volatility-spike filter + position sizing theo % risk.
  Kết quả: PF 1.463, p-value 0.0067 (n=500 permutation).
- `XAUUSD_RegimeBot_M30.mq5` — bản M30 tương tự, tham số riêng (ADX 25/15, mom 1.5, z-period 30).
  Kết quả: PF 1.476, p-value ~0.0000 (n=300).
  ⚠️ Tương quan PnL với bản H1 = 0.918 — KHÔNG phải chiến lược độc lập, đừng bán như "đa dạng hóa".
- `XAUUSD_H1_Ratchet_EA_enhanced_v2.mq5` — EA khác (không phải của mình, user cung cấp) đã được
  thêm filter MA50+ADX+Vol-spike (KHÔNG dùng DXY, KHÔNG dùng ATR-based-SL vì test cho thấy có hại
  trên chính hệ thống entry này — candle-pattern + EMA/BB, khác hẳn regime-detection).
  Kết quả: PF 1.255, PnL 1662, p-value <0.017 (n=60).

## Phát hiện quan trọng cần nhớ
1. **Z-score/mean-reversion trên chính giá vàng KHÔNG có cơ sở thống kê** (IC dương thay vì âm ở
   mọi ngưỡng/horizon test) — đã loại bỏ khỏi bot chính.
2. **Điểm yếu chung xuyên suốt mọi hệ thống** (H1, M30, Ratchet-EA): giai đoạn "grinding trend"
   (ADX sát ngưỡng 25-28, biến động THẤP hơn bình thường, xu hướng yếu nhiều nhiễu) luôn gây
   chuỗi thua dài (8-11 lệnh) hoặc quý âm — không phải lỗi code, là đặc tính cấu trúc của vàng.
3. **M5 và M15 không khả thi** — spread/ATR quá cao (4.83%/3.53%), walk-forward không hội tụ.
   M30 khả thi tốt, gần ngang H1.
4. **Multiple-testing bias**: đã thử hàng chục biến thể trong phiên — p-value cuối chưa hiệu
   chỉnh cho việc "chọn ra cái tốt nhất từ nhiều lần thử". Forward test demo 8-12 tuần là bài
   kiểm tra thực sự đáng tin (xem file Forward_Test_Plan_XAUUSD_Bot.md đã tạo).

## ĐANG LÀM DỞ — việc cần tiếp tục ở chat mới
Đang xây **tín hiệu liên thị trường thay thế cho nhánh RANGE/z-score đã bị loại bỏ**, dùng
**tỷ lệ XAU/XAG (Gold/Silver ratio)** thay vì mean-reversion trên giá vàng đơn lẻ.

**Đã hoàn thành:** IC Analysis sơ bộ cho thấy tín hiệu THẬT:
- `ratio_change_5` (thay đổi tỷ lệ XAU/XAG trong 5 nến gần nhất) có IC = **-0.0513 (p=0.0000)**
  với return 20 nến sau của vàng, **trong giai đoạn grinding (ADX≤28)** — mạnh hơn hẳn so với
  IC trên toàn bộ dữ liệu (-0.031).
- USD/JPY: KHÔNG có ý nghĩa thống kê (p>0.16 mọi trường hợp) — đã loại bỏ hướng này.
- Diễn giải: khi vàng gần đây "chạy nhanh hơn" bạc (ratio tăng), return vàng sắp tới có xu
  hướng ÂM (đảo chiều tương đối, không phải mean-reversion tuyệt đối như z-score cũ).

**Việc cần làm tiếp (theo đúng quy trình đã dùng xuyên suốt dự án):**
1. Xây tín hiệu entry cụ thể từ `ratio_change_5` (chọn ngưỡng threshold, có thể cần walk-forward
   để tìm ngưỡng tối ưu — tương tự cách đã làm với ADX/momentum/z-score cũ)
2. Thay thế nhánh RANGE/z-score cũ trong bot H1 bằng tín hiệu XAU/XAG-ratio mới này
3. Backtest full: so sánh bản "chỉ TREND/momentum" (baseline đã có, PF~1.468) vs
   "TREND/momentum + XAU/XAG-ratio-reversion mới" — xem có cải thiện thật không
4. Walk-forward optimization cho ngưỡng ratio_change threshold
5. Permutation test đầy đủ (n≥300) để xác nhận ý nghĩa thống kê trước khi tin dùng
6. Nếu tốt: cập nhật vào `XAUUSD_RegimeBot_v4.mq5` (cần thêm iClose cho symbol XAGUSD trong MQL5)

## Dữ liệu đã có sẵn (đã upload trong phiên trước, cần upload lại ở chat mới)
- XAUUSD: H1, H4, M5, M15, M30 (2023-2026)
- DXY: H1, H4
- DFII10 (real yield, đã thử nhưng không tốt bằng DXY, có thể bỏ qua)
- XAGUSD: H1 (2023-07 đến 2026-09) — MỚI, dùng cho hướng đang làm dở
- USDJPY: H1 — đã test, không hữu ích, không cần dùng nữa

## Lưu ý kỹ thuật khi tiếp tục
- Mọi backtest đều dùng Python (pandas), không phải MT5 Strategy Tester thật — cần forward test
  demo thật trước khi launch.
- Point size XAUUSD = 0.001 (3 chữ số thập phân) trong dữ liệu đang dùng.
- Spread trung bình H1: ~130 points (~$0.13).
- Entry luôn tại giá OPEN của nến kế tiếp sau tín hiệu (tránh lookahead bias).
