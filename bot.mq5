//+------------------------------------------------------------------+
//|                                          HybridAlpha2026.mq5    |
//|                         Hybrid Alpha 2026 — Expert Advisor      |
//|  Strategia: SMC (OB+FVG+Liquidity+BOS) + EMA/RSI/ATR/Volume    |
//|  Filtr AI  : Claude API (opcjonalny)                            |
//|  Zarządzanie: Pyramid Basket + Trailing Stop + Break-Even        |
//|  Backtest  : wbudowany moduł statystyczny                       |
//+------------------------------------------------------------------+
#property copyright "Hybrid Alpha 2026"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//|  SEKCJA INPUT — wszystkie parametry konfigurowalne               |
//+------------------------------------------------------------------+

// --- Instrument i timeframe
input group "=== INSTRUMENT & TIMEFRAME ==="
input string   InpSymbol            = "";          // Symbol (puste = bieżący)
input ENUM_TIMEFRAMES InpTF_Main    = PERIOD_H1;   // Główny timeframe
input ENUM_TIMEFRAMES InpTF_HTF     = PERIOD_H4;   // Wyższy timeframe (kontekst)
input ENUM_TIMEFRAMES InpTF_Entry   = PERIOD_M5;   // Timeframe wejścia

// --- SMC Engine
input group "=== SMC ENGINE ==="
input bool     InpUseOrderBlocks    = true;        // Używaj Order Blocks
input bool     InpUseFVG            = true;        // Używaj Fair Value Gap
input bool     InpUseLiquidity      = true;        // Używaj Liquidity Sweep
input bool     InpUseBOS            = true;        // Używaj BOS / CHoCH
input int      InpOB_LookbackBars   = 50;          // OB: liczba świec wstecz
input int      InpFVG_MinPips       = 5;           // FVG: minimalna wielkość (pips)
input int      InpLiq_LookbackBars  = 30;          // Liquidity: liczba świec wstecz
input double   InpLiq_SweepPips     = 3.0;         // Liquidity: sweep w pips

// --- Wskaźniki klasyczne
input group "=== WSKAZNIKI KLASYCZNE ==="
input int      InpEMA_Period        = 200;         // EMA: okres
input int      InpRSI_Period        = 14;          // RSI: okres
input double   InpRSI_OB            = 70.0;        // RSI: poziom wykupienia
input double   InpRSI_OS            = 30.0;        // RSI: poziom wyprzedania
input int      InpATR_Period        = 14;          // ATR: okres
input double   InpATR_SL_Mult       = 1.5;         // ATR: mnożnik Stop Loss
input double   InpATR_TP_Mult       = 3.0;         // ATR: mnożnik Take Profit
input bool     InpUseVolume         = true;        // Filtr wolumenu

// --- Zarządzanie pozycjami
input group "=== ZARZADZANIE POZYCJAMI ==="
input int      InpMaxPositions      = 5;           // Max pozycji jednocześnie
input int      InpMaxPositionsTotal = 10;          // Max pozycji łącznie (wszystkie symbole)
input double   InpRiskPercent       = 2.0;         // Ryzyko na transakcję (% depozytu)
input double   InpMinLot            = 0.01;        // Minimalny lot
input double   InpMaxLot            = 5.0;         // Maksymalny lot
input bool     InpUsePyramid        = true;        // Pyramid (dokładanie pozycji)
input int      InpPyramidMax        = 3;           // Pyramid: max dokładanie
input double   InpPyramidATRStep    = 1.0;         // Pyramid: krok w ATR
input bool     InpUseTrailing       = true;        // Trailing Stop
input double   InpTrailActivateATR  = 1.0;         // Trailing: aktywacja (× ATR)
input double   InpTrailStepATR      = 0.5;         // Trailing: krok (× ATR)
input bool     InpUseBreakEven      = true;        // Break-Even koszyka
input double   InpBE_TriggerATR     = 1.5;         // Break-Even: trigger (× ATR)

// --- Ochrona kapitału
input group "=== OCHRONA KAPITALU ==="
input double   InpMaxDailyLoss      = 5.0;         // Max dzienna strata (% balansu)
input double   InpMaxDrawdown       = 15.0;        // Max drawdown (% balansu)
input bool     InpUseNewsFilter     = false;       // Filtr newsów (wstrzymanie przed wysoką zmiennością)
input int      InpNewsMinutesBefore = 30;          // Filtr newsów: minuty przed

// --- Filtr AI (Claude API)
input group "=== FILTR AI (CLAUDE API) ==="
input bool     InpUseAI             = false;       // Włącz filtr AI
input string   InpAI_ApiKey         = "";          // Claude API Key
input string   InpAI_Model          = "claude-sonnet-4-20250514"; // Model
input int      InpAI_Timeout        = 5000;        // Timeout (ms)
input double   InpAI_MinScore       = 0.65;        // Min. wynik AI (0–1) do akceptacji

// --- Backtest / Statystyki
input group "=== BACKTEST & STATYSTYKI ==="
input bool     InpSaveStats         = true;        // Zapisuj statystyki do CSV
input string   InpStatsFile         = "HybridAlpha_stats.csv"; // Nazwa pliku
input bool     InpShowDashboard     = true;        // Pokaż panel na wykresie

// --- Sesje handlowe
input group "=== SESJE ==="
input bool     InpUseSessionFilter  = true;        // Filtr sesji
input int      InpSessionStartHour  = 7;           // Start sesji (UTC)
input int      InpSessionEndHour    = 22;          // Koniec sesji (UTC)
input bool     InpTradeFriday       = false;       // Handel w piątek (po 18:00 UTC)

//+------------------------------------------------------------------+
//|  STRUKTURY DANYCH                                                |
//+------------------------------------------------------------------+

struct OrderBlock {
   double   priceHigh;
   double   priceLow;
   double   priceMid;
   bool     isBullish;
   datetime time;
   bool     mitigated;
};

struct FairValueGap {
   double   gapHigh;
   double   gapLow;
   bool     isBullish;
   datetime time;
   bool     filled;
};

struct LiquidityLevel {
   double   price;
   bool     isBSL;          // true = buy-side, false = sell-side
   datetime time;
   bool     swept;
};

struct TradeSignal {
   bool     isValid;
   int      direction;      // 1=BUY, -1=SELL
   double   entryPrice;
   double   stopLoss;
   double   takeProfit;
   double   lotSize;
   string   reason;
   double   aiScore;
};

struct BacktestStats {
   int      totalTrades;
   int      winTrades;
   int      lossTrades;
   double   totalProfit;
   double   totalLoss;
   double   maxDrawdown;
   double   winRate;
   double   profitFactor;
   double   avgWin;
   double   avgLoss;
   double   sharpeRatio;
   double   peakEquity;
   double   currentEquity;
};

//+------------------------------------------------------------------+
//|  ZMIENNE GLOBALNE                                                |
//+------------------------------------------------------------------+

CTrade         g_trade;
CPositionInfo  g_position;
CAccountInfo   g_account;

string         g_symbol;
double         g_point;
int            g_digits;
double         g_pipValue;

// Uchwyty wskaźników
int            g_hEMA_Main, g_hEMA_HTF;
int            g_hRSI_Main;
int            g_hATR_Main;
int            g_hVolume_Main;

// Bufory SMC
OrderBlock     g_orderBlocks[];
FairValueGap   g_fvgZones[];
LiquidityLevel g_liquidityLevels[];
bool           g_bosDetected;
bool           g_chochDetected;
int            g_structureBias; // 1=bullish, -1=bearish, 0=neutral

// Zarządzanie ryzykiem
double         g_dailyStartBalance;
double         g_peakBalance;
bool           g_botDisabledToday;
datetime       g_lastDayCheck;
int            g_pyramidCount[];  // licznik dokładania per magic

// Statystyki backtestowe
BacktestStats  g_stats;
int            g_statsFileHandle;

// Dashboard
int            g_labelHandles[];

// Magic numbers per pozycja
ulong          g_magicBase = 202600;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit() {
   g_symbol  = (InpSymbol == "") ? _Symbol : InpSymbol;
   g_point   = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_digits  = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_pipValue = (g_digits == 5 || g_digits == 3) ? g_point * 10 : g_point;

   // --- Inicjalizacja wskaźników
   g_hEMA_Main  = iMA(g_symbol, InpTF_Main,  InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA_HTF   = iMA(g_symbol, InpTF_HTF,   InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI_Main  = iRSI(g_symbol, InpTF_Main, InpRSI_Period, PRICE_CLOSE);
   g_hATR_Main  = iATR(g_symbol, InpTF_Main, InpATR_Period);
   g_hVolume_Main = iVolumes(g_symbol, InpTF_Main, VOLUME_TICK);

   if(g_hEMA_Main == INVALID_HANDLE || g_hRSI_Main == INVALID_HANDLE ||
      g_hATR_Main == INVALID_HANDLE) {
      Print("[INIT ERROR] Nie można zainicjować wskaźników!");
      return INIT_FAILED;
   }

   // --- CTrade setup
   g_trade.SetExpertMagicNumber(g_magicBase);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   // --- Ochrona kapitału — punkt startowy
   g_dailyStartBalance = g_account.Balance();
   g_peakBalance       = g_account.Balance();
   g_botDisabledToday  = false;
   g_lastDayCheck      = TimeCurrent();

   // --- Statystyki
   ZeroMemory(g_stats);
   g_stats.peakEquity    = g_account.Equity();
   g_stats.currentEquity = g_account.Equity();

   if(InpSaveStats) {
      g_statsFileHandle = FileOpen(InpStatsFile, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(g_statsFileHandle != INVALID_HANDLE) {
         FileWrite(g_statsFileHandle,
            "Time","Symbol","Direction","EntryPrice","SL","TP","Lots",
            "Profit","Reason","AIScore","WinRate","ProfitFactor");
         FileFlush(g_statsFileHandle);
      }
   }

   Print("[INIT OK] HybridAlpha2026 uruchomiony na ", g_symbol,
         " TF:", EnumToString(InpTF_Main));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(InpSaveStats && g_statsFileHandle != INVALID_HANDLE) {
      WriteStatsSummary();
      FileClose(g_statsFileHandle);
   }
   IndicatorRelease(g_hEMA_Main);
   IndicatorRelease(g_hEMA_HTF);
   IndicatorRelease(g_hRSI_Main);
   IndicatorRelease(g_hATR_Main);
   IndicatorRelease(g_hVolume_Main);
   CleanDashboard();
   Print("[DEINIT] Statystyki zapisane. Powód: ", reason);
}

//+------------------------------------------------------------------+
//|  OnTick — główna pętla                                           |
//+------------------------------------------------------------------+
void OnTick() {
   // Sprawdź nową świecę (logika tylko na zamknięciu)
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(g_symbol, InpTF_Main, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   if(isNewBar) lastBarTime = currentBarTime;

   // --- Aktualizacja equity / ochrona kapitału
   UpdateEquityProtection();
   if(g_botDisabledToday) {
      if(InpShowDashboard) UpdateDashboard("BOT WYŁĄCZONY — limit dzienny osiągnięty");
      return;
   }

   // --- Zarządzanie otwartymi pozycjami (każdy tick)
   ManageOpenPositions();

   // --- Logika sygnałów tylko na nowej świecy
   if(!isNewBar) return;

   // --- Sprawdź sesję handlową
   if(InpUseSessionFilter && !IsInTradingSession()) return;

   // --- Aktualizuj dzień
   CheckNewDay();

   // --- Aktualizuj SMC
   UpdateSMCEngine();

   // --- Generuj sygnał
   TradeSignal signal;
   signal.isValid = false;

   if(CountOpenPositions() < InpMaxPositions) {
      signal = GenerateSignal();
   }

   // --- Sprawdź sygnał pyramid (dokładanie)
   if(InpUsePyramid && CountOpenPositions() > 0) {
      CheckPyramidEntry();
   }

   // --- Wykonaj transakcję
   if(signal.isValid) {
      // Filtr AI
      if(InpUseAI) {
         signal.aiScore = GetAIScore(signal);
         if(signal.aiScore < InpAI_MinScore) {
            LogDecision(signal, false, "AI_SKIP score=" + DoubleToString(signal.aiScore, 2));
            if(InpShowDashboard) UpdateDashboard("AI ODRZUCIŁ setup (score: " +
               DoubleToString(signal.aiScore, 2) + ")");
            return;
         }
      }

      ExecuteTrade(signal);
   }

   // --- Dashboard
   if(InpShowDashboard) UpdateDashboard("");
}

//+------------------------------------------------------------------+
//|  SMC ENGINE                                                      |
//+------------------------------------------------------------------+

void UpdateSMCEngine() {
   if(InpUseOrderBlocks)  DetectOrderBlocks();
   if(InpUseFVG)          DetectFVG();
   if(InpUseLiquidity)    DetectLiquidityLevels();
   if(InpUseBOS)          DetectBOS_CHoCH();
}

// --- Order Blocks ---
void DetectOrderBlocks() {
   ArrayResize(g_orderBlocks, 0);
   int lookback = MathMin(InpOB_LookbackBars, iBars(g_symbol, InpTF_Main) - 2);

   for(int i = 1; i < lookback; i++) {
      double open1  = iOpen(g_symbol,  InpTF_Main, i);
      double close1 = iClose(g_symbol, InpTF_Main, i);
      double high1  = iHigh(g_symbol,  InpTF_Main, i);
      double low1   = iLow(g_symbol,   InpTF_Main, i);
      double open0  = iOpen(g_symbol,  InpTF_Main, i-1);
      double close0 = iClose(g_symbol, InpTF_Main, i-1);

      bool isBullishOB = (close1 < open1) &&  // świeca poprzednia bearish
                         (close0 > open0) &&   // świeca aktualna bullish
                         (close0 > high1);     // przebicie powyżej OB

      bool isBearishOB = (close1 > open1) &&
                         (close0 < open0) &&
                         (close0 < low1);

      if(isBullishOB || isBearishOB) {
         OrderBlock ob;
         ob.isBullish  = isBullishOB;
         ob.priceHigh  = high1;
         ob.priceLow   = low1;
         ob.priceMid   = (high1 + low1) / 2.0;
         ob.time       = iTime(g_symbol, InpTF_Main, i);
         ob.mitigated  = false;

         // Sprawdź czy OB nie został już zneutralizowany
         double currentPrice = SymbolInfoDouble(g_symbol, SYMBOL_BID);
         if(isBullishOB && currentPrice < ob.priceLow)  ob.mitigated = true;
         if(isBearishOB && currentPrice > ob.priceHigh) ob.mitigated = true;

         int sz = ArraySize(g_orderBlocks);
         ArrayResize(g_orderBlocks, sz + 1);
         g_orderBlocks[sz] = ob;
      }
   }
}

// --- Fair Value Gaps ---
void DetectFVG() {
   ArrayResize(g_fvgZones, 0);
   double minFVG = InpFVG_MinPips * g_pipValue;
   int lookback = MathMin(100, iBars(g_symbol, InpTF_Main) - 3);

   for(int i = 2; i < lookback; i++) {
      double high2 = iHigh(g_symbol, InpTF_Main, i);
      double low2  = iLow(g_symbol,  InpTF_Main, i);
      double high1 = iHigh(g_symbol, InpTF_Main, i-1);  // świeca środkowa (impulse)
      double low1  = iLow(g_symbol,  InpTF_Main, i-1);
      double high0 = iHigh(g_symbol, InpTF_Main, i-2);
      double low0  = iLow(g_symbol,  InpTF_Main, i-2);

      // Bullish FVG: low świecy i > high świecy i-2
      if(low2 > high0 && (low2 - high0) >= minFVG) {
         FairValueGap fvg;
         fvg.isBullish = true;
         fvg.gapHigh   = low2;
         fvg.gapLow    = high0;
         fvg.time      = iTime(g_symbol, InpTF_Main, i);
         fvg.filled    = false;
         double price  = SymbolInfoDouble(g_symbol, SYMBOL_BID);
         if(price <= fvg.gapHigh && price >= fvg.gapLow) fvg.filled = false; // cena w FVG
         else if(price < fvg.gapLow) fvg.filled = true;
         int sz = ArraySize(g_fvgZones);
         ArrayResize(g_fvgZones, sz + 1);
         g_fvgZones[sz] = fvg;
      }

      // Bearish FVG: high świecy i < low świecy i-2
      if(high2 < low0 && (low0 - high2) >= minFVG) {
         FairValueGap fvg;
         fvg.isBullish = false;
         fvg.gapHigh   = low0;
         fvg.gapLow    = high2;
         fvg.time      = iTime(g_symbol, InpTF_Main, i);
         fvg.filled    = false;
         double price  = SymbolInfoDouble(g_symbol, SYMBOL_BID);
         if(price >= fvg.gapLow && price <= fvg.gapHigh) fvg.filled = false;
         else if(price > fvg.gapHigh) fvg.filled = true;
         int sz = ArraySize(g_fvgZones);
         ArrayResize(g_fvgZones, sz + 1);
         g_fvgZones[sz] = fvg;
      }
   }
}

// --- Liquidity Sweep ---
void DetectLiquidityLevels() {
   ArrayResize(g_liquidityLevels, 0);
   double sweepThreshold = InpLiq_SweepPips * g_pipValue;
   int lookback = MathMin(InpLiq_LookbackBars, iBars(g_symbol, InpTF_Main) - 1);

   // Szukaj swing highs i swing lows
   for(int i = 2; i < lookback - 2; i++) {
      double high_i  = iHigh(g_symbol, InpTF_Main, i);
      double low_i   = iLow(g_symbol,  InpTF_Main, i);
      double high_l  = iHigh(g_symbol, InpTF_Main, i+1);
      double high_r  = iHigh(g_symbol, InpTF_Main, i-1);
      double low_l   = iLow(g_symbol,  InpTF_Main, i+1);
      double low_r   = iLow(g_symbol,  InpTF_Main, i-1);

      // Swing High (Buy-Side Liquidity — SL buyerów)
      if(high_i > high_l && high_i > high_r) {
         LiquidityLevel liq;
         liq.price = high_i;
         liq.isBSL = true;
         liq.time  = iTime(g_symbol, InpTF_Main, i);
         liq.swept = false;
         // Sprawdź czy sweep już nastąpił
         for(int j = i-1; j >= 1; j--) {
            double hj = iHigh(g_symbol, InpTF_Main, j);
            double cj = iClose(g_symbol, InpTF_Main, j);
            if(hj > liq.price + sweepThreshold && cj < liq.price) {
               liq.swept = true; break;
            }
         }
         int sz = ArraySize(g_liquidityLevels);
         ArrayResize(g_liquidityLevels, sz + 1);
         g_liquidityLevels[sz] = liq;
      }

      // Swing Low (Sell-Side Liquidity — SL sellerów)
      if(low_i < low_l && low_i < low_r) {
         LiquidityLevel liq;
         liq.price = low_i;
         liq.isBSL = false;
         liq.time  = iTime(g_symbol, InpTF_Main, i);
         liq.swept = false;
         for(int j = i-1; j >= 1; j--) {
            double lj = iLow(g_symbol,  InpTF_Main, j);
            double cj = iClose(g_symbol, InpTF_Main, j);
            if(lj < liq.price - sweepThreshold && cj > liq.price) {
               liq.swept = true; break;
            }
         }
         int sz = ArraySize(g_liquidityLevels);
         ArrayResize(g_liquidityLevels, sz + 1);
         g_liquidityLevels[sz] = liq;
      }
   }
}

// --- BOS / CHoCH ---
void DetectBOS_CHoCH() {
   g_bosDetected   = false;
   g_chochDetected = false;
   g_structureBias = 0;

   int lookback = MathMin(50, iBars(g_symbol, InpTF_Main) - 2);
   double prevSwingHigh = 0, prevSwingLow = DBL_MAX;

   for(int i = lookback; i >= 2; i--) {
      double h = iHigh(g_symbol, InpTF_Main, i);
      double l = iLow(g_symbol,  InpTF_Main, i);
      if(h > prevSwingHigh) prevSwingHigh = h;
      if(l < prevSwingLow)  prevSwingLow  = l;
   }

   double currentClose = iClose(g_symbol, InpTF_Main, 1);
   double prevClose    = iClose(g_symbol, InpTF_Main, 2);

   // BOS Bullish: zamknięcie powyżej poprzedniego swing high
   if(currentClose > prevSwingHigh && prevClose <= prevSwingHigh) {
      g_bosDetected   = true;
      g_structureBias = 1;
   }
   // BOS Bearish: zamknięcie poniżej poprzedniego swing low
   else if(currentClose < prevSwingLow && prevClose >= prevSwingLow) {
      g_bosDetected   = true;
      g_structureBias = -1;
   }

   // CHoCH: zmiana charakteru (wcześniejszy trend był przeciwny)
   // Uproszczona wersja: sprawdzamy ostatnie 10 świec
   int upCandles = 0, downCandles = 0;
   for(int i = 2; i <= 12; i++) {
      double c = iClose(g_symbol, InpTF_Main, i);
      double o = iOpen(g_symbol,  InpTF_Main, i);
      if(c > o) upCandles++;
      else      downCandles++;
   }
   if(g_bosDetected) {
      if(g_structureBias == 1 && downCandles > upCandles)  g_chochDetected = true;
      if(g_structureBias == -1 && upCandles > downCandles) g_chochDetected = true;
   }
}

//+------------------------------------------------------------------+
//|  GENEROWANIE SYGNAŁU                                             |
//+------------------------------------------------------------------+

TradeSignal GenerateSignal() {
   TradeSignal sig;
   sig.isValid  = false;
   sig.aiScore  = 1.0;

   // --- Pobierz bufory wskaźników
   double ema_main[3], ema_htf[2], rsi_buf[3], atr_buf[2];
   if(CopyBuffer(g_hEMA_Main, 0, 0, 3, ema_main) < 3) return sig;
   if(CopyBuffer(g_hEMA_HTF,  0, 0, 2, ema_htf)  < 2) return sig;
   if(CopyBuffer(g_hRSI_Main, 0, 0, 3, rsi_buf)  < 3) return sig;
   if(CopyBuffer(g_hATR_Main, 0, 0, 2, atr_buf)  < 2) return sig;

   double ema    = ema_main[0];
   double emaHTF = ema_htf[0];
   double rsi    = rsi_buf[1]; // poprzednia zamknięta świeca
   double rsiPrev= rsi_buf[2];
   double atr    = atr_buf[1];
   double price  = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double close1 = iClose(g_symbol, InpTF_Main, 1);
   double close2 = iClose(g_symbol, InpTF_Main, 2);

   // --- Warunek wolumenu
   bool volOK = true;
   if(InpUseVolume) {
      double vol[3];
      if(CopyBuffer(g_hVolume_Main, 0, 0, 3, vol) >= 3) {
         double avgVol = (vol[1] + vol[2]) / 2.0;
         volOK = (vol[1] > avgVol * 1.2); // wolumen 20% powyżej średniej
      }
   }

   // --- HTF bias (wyższy timeframe musi zgadzać się z kierunkiem)
   bool htfBullish = (price > emaHTF);
   bool htfBearish = (price < emaHTF);

   // === SYGNAŁ LONG ===
   bool longCondition = false;
   string longReason  = "";

   // Podstawa: cena > EMA, RSI wychodzi z wyprzedania
   bool ema_long = (close1 > ema && close2 < ema) || (close1 > ema && rsi < 50);
   bool rsi_long = (rsiPrev < InpRSI_OS && rsi > InpRSI_OS);  // crossover z OS

   // SMC potwierdzenia
   bool obLong  = !InpUseOrderBlocks || IsNearBullishOB(price, atr);
   bool fvgLong = !InpUseFVG         || IsInBullishFVG(price);
   bool liqLong = !InpUseLiquidity   || WasSSLSwept();
   bool bosLong = !InpUseBOS         || (g_structureBias >= 0);

   if(htfBullish && ema_long && rsi_long && obLong && fvgLong && liqLong && bosLong && volOK) {
      longCondition = true;
      longReason = "LONG: EMA+RSI+SMC";
      if(g_bosDetected && g_structureBias == 1) longReason += "+BOS";
      if(g_chochDetected)                       longReason += "+CHoCH";
   }

   // === SYGNAŁ SHORT ===
   bool shortCondition = false;
   string shortReason  = "";

   bool ema_short = (close1 < ema && close2 > ema) || (close1 < ema && rsi > 50);
   bool rsi_short = (rsiPrev > InpRSI_OB && rsi < InpRSI_OB);

   bool obShort  = !InpUseOrderBlocks || IsNearBearishOB(price, atr);
   bool fvgShort = !InpUseFVG         || IsInBearishFVG(price);
   bool liqShort = !InpUseLiquidity   || WasBSLSwept();
   bool bosShort = !InpUseBOS         || (g_structureBias <= 0);

   if(htfBearish && ema_short && rsi_short && obShort && fvgShort && liqShort && bosShort && volOK) {
      shortCondition = true;
      shortReason = "SHORT: EMA+RSI+SMC";
      if(g_bosDetected && g_structureBias == -1) shortReason += "+BOS";
      if(g_chochDetected)                        shortReason += "+CHoCH";
   }

   // --- Zbuduj sygnał
   if(!longCondition && !shortCondition) return sig;

   int direction = longCondition ? 1 : -1;
   double sl, tp, entry;

   if(direction == 1) {
      entry = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      sl    = entry - atr * InpATR_SL_Mult;
      tp    = entry + atr * InpATR_TP_Mult;
      sig.reason = longReason;
   } else {
      entry = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      sl    = entry + atr * InpATR_SL_Mult;
      tp    = entry - atr * InpATR_TP_Mult;
      sig.reason = shortReason;
   }

   // Normalizacja cen
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   double lot = CalculateLotSize(entry, sl);
   if(lot < InpMinLot) return sig;

   sig.isValid    = true;
   sig.direction  = direction;
   sig.entryPrice = entry;
   sig.stopLoss   = sl;
   sig.takeProfit = tp;
   sig.lotSize    = lot;

   return sig;
}

//+------------------------------------------------------------------+
//|  SMC HELPER FUNCTIONS                                            |
//+------------------------------------------------------------------+

bool IsNearBullishOB(double price, double atr) {
   double tolerance = atr * 0.3;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++) {
      if(g_orderBlocks[i].isBullish && !g_orderBlocks[i].mitigated) {
         if(price >= g_orderBlocks[i].priceLow - tolerance &&
            price <= g_orderBlocks[i].priceHigh + tolerance) return true;
      }
   }
   return false;
}

bool IsNearBearishOB(double price, double atr) {
   double tolerance = atr * 0.3;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++) {
      if(!g_orderBlocks[i].isBullish && !g_orderBlocks[i].mitigated) {
         if(price >= g_orderBlocks[i].priceLow - tolerance &&
            price <= g_orderBlocks[i].priceHigh + tolerance) return true;
      }
   }
   return false;
}

bool IsInBullishFVG(double price) {
   for(int i = 0; i < ArraySize(g_fvgZones); i++) {
      if(g_fvgZones[i].isBullish && !g_fvgZones[i].filled) {
         if(price >= g_fvgZones[i].gapLow && price <= g_fvgZones[i].gapHigh) return true;
      }
   }
   return false;
}

bool IsInBearishFVG(double price) {
   for(int i = 0; i < ArraySize(g_fvgZones); i++) {
      if(!g_fvgZones[i].isBullish && !g_fvgZones[i].filled) {
         if(price >= g_fvgZones[i].gapLow && price <= g_fvgZones[i].gapHigh) return true;
      }
   }
   return false;
}

bool WasSSLSwept() {
   // Sprawdź czy sell-side liquidity była zmieciona (znak, że smart money akumuluje long)
   for(int i = 0; i < ArraySize(g_liquidityLevels); i++) {
      if(!g_liquidityLevels[i].isBSL && g_liquidityLevels[i].swept) return true;
   }
   return false;
}

bool WasBSLSwept() {
   for(int i = 0; i < ArraySize(g_liquidityLevels); i++) {
      if(g_liquidityLevels[i].isBSL && g_liquidityLevels[i].swept) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  FILTR AI — Claude API                                           |
//+------------------------------------------------------------------+

double GetAIScore(TradeSignal &sig) {
   if(!InpUseAI || InpAI_ApiKey == "") return 1.0;

   // Buduj JSON payload
   string payload = StringFormat(
      "{\"model\":\"%s\",\"max_tokens\":100,"
      "\"messages\":[{\"role\":\"user\",\"content\":"
      "\"You are a professional trading analyst. Rate this trade setup from 0.0 to 1.0.\\n"
      "Symbol: %s | Direction: %s | Price: %.5f | SL: %.5f | TP: %.5f\\n"
      "SMC signals: %s | RSI context: active | ATR-based sizing: yes\\n"
      "Respond ONLY with a JSON: {\\\"score\\\": 0.XX, \\\"pass\\\": true/false}\"}]}",
      InpAI_Model,
      g_symbol,
      sig.direction == 1 ? "BUY" : "SELL",
      sig.entryPrice, sig.stopLoss, sig.takeProfit,
      sig.reason
   );

   string headers = "Content-Type: application/json\r\n"
                    "x-api-key: " + InpAI_ApiKey + "\r\n"
                    "anthropic-version: 2023-06-01\r\n";

   char post[], result[];
   StringToCharArray(payload, post, 0, StringLen(payload));

   int httpCode = WebRequest(
      "POST",
      "https://api.anthropic.com/v1/messages",
      headers,
      InpAI_Timeout,
      post,
      result,
      headers
   );

   if(httpCode != 200) {
      Print("[AI] HTTP error: ", httpCode);
      return 1.0; // fallback: przepuść sygnał
   }

   string response = CharArrayToString(result);

   // Parsuj score z odpowiedzi
   int pos = StringFind(response, "\"score\":");
   if(pos < 0) return 1.0;
   string scoreStr = StringSubstr(response, pos + 8, 6);
   double score = StringToDouble(scoreStr);
   if(score < 0.0 || score > 1.0) score = 1.0;

   Print("[AI] Setup score: ", DoubleToString(score, 2), " dla ", sig.reason);
   return score;
}

//+------------------------------------------------------------------+
//|  EGZEKUCJA TRANSAKCJI                                            |
//+------------------------------------------------------------------+

void ExecuteTrade(TradeSignal &sig) {
   if(!sig.isValid) return;

   // Sprawdź spread
   double spread = SymbolInfoInteger(g_symbol, SYMBOL_SPREAD) * g_point;
   double atrVal[2];
   CopyBuffer(g_hATR_Main, 0, 0, 2, atrVal);
   if(spread > atrVal[1] * 0.3) {
      Print("[EXEC] Spread zbyt wysoki: ", spread, " > ", atrVal[1] * 0.3);
      return;
   }

   bool ok = false;
   if(sig.direction == 1)
      ok = g_trade.Buy(sig.lotSize, g_symbol, sig.entryPrice, sig.stopLoss, sig.takeProfit, sig.reason);
   else
      ok = g_trade.Sell(sig.lotSize, g_symbol, sig.entryPrice, sig.stopLoss, sig.takeProfit, sig.reason);

   if(ok) {
      Print("[TRADE OPEN] ", sig.direction == 1 ? "BUY" : "SELL",
            " Lot:", sig.lotSize, " SL:", sig.stopLoss, " TP:", sig.takeProfit,
            " Score:", sig.aiScore, " Reason:", sig.reason);
      LogDecision(sig, true, "EXECUTED");
      UpdateStats_Open(sig);
   } else {
      Print("[EXEC ERROR] ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//|  ZARZĄDZANIE OTWARTYMI POZYCJAMI                                 |
//+------------------------------------------------------------------+

void ManageOpenPositions() {
   double atr[2];
   if(CopyBuffer(g_hATR_Main, 0, 0, 2, atr) < 2) return;
   double atrVal = atr[1];

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!g_position.SelectByIndex(i)) continue;
      if(g_position.Symbol() != g_symbol) continue;
      if(g_position.Magic() != g_magicBase) continue;

      double openPrice = g_position.PriceOpen();
      double sl        = g_position.StopLoss();
      double tp        = g_position.TakeProfit();
      double curPrice  = (g_position.PositionType() == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(g_symbol, SYMBOL_BID)
                         : SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      double profit    = g_position.Profit();
      ulong  ticket    = g_position.Ticket();

      // --- Break-Even
      if(InpUseBreakEven) {
         double beTrigger = atrVal * InpBE_TriggerATR;
         if(g_position.PositionType() == POSITION_TYPE_BUY) {
            if(curPrice >= openPrice + beTrigger && sl < openPrice) {
               double newSL = openPrice + g_point * 2;
               newSL = NormalizeDouble(newSL, g_digits);
               if(newSL > sl)
                  g_trade.PositionModify(ticket, newSL, tp);
            }
         } else {
            if(curPrice <= openPrice - beTrigger && sl > openPrice) {
               double newSL = openPrice - g_point * 2;
               newSL = NormalizeDouble(newSL, g_digits);
               if(newSL < sl)
                  g_trade.PositionModify(ticket, newSL, tp);
            }
         }
      }

      // --- Trailing Stop
      if(InpUseTrailing) {
         double trailActivate = atrVal * InpTrailActivateATR;
         double trailStep     = atrVal * InpTrailStepATR;

         if(g_position.PositionType() == POSITION_TYPE_BUY) {
            if(curPrice >= openPrice + trailActivate) {
               double newSL = curPrice - trailStep;
               newSL = NormalizeDouble(newSL, g_digits);
               if(newSL > sl + g_point)
                  g_trade.PositionModify(ticket, newSL, tp);
            }
         } else {
            if(curPrice <= openPrice - trailActivate) {
               double newSL = curPrice + trailStep;
               newSL = NormalizeDouble(newSL, g_digits);
               if(newSL < sl - g_point || sl == 0)
                  g_trade.PositionModify(ticket, newSL, tp);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  PYRAMID (dokładanie pozycji)                                    |
//+------------------------------------------------------------------+

void CheckPyramidEntry() {
   if(!InpUsePyramid) return;
   int openCount = CountOpenPositions();
   if(openCount >= InpMaxPositions || openCount >= InpPyramidMax) return;

   double atr[2];
   if(CopyBuffer(g_hATR_Main, 0, 0, 2, atr) < 2) return;
   double atrVal = atr[1];

   // Sprawdź kierunek istniejących pozycji
   int existingDir = 0;
   double avgEntry = 0;
   int posCount = 0;

   for(int i = 0; i < PositionsTotal(); i++) {
      if(!g_position.SelectByIndex(i)) continue;
      if(g_position.Symbol() != g_symbol) continue;
      if(g_position.Magic() != g_magicBase) continue;
      existingDir = (g_position.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
      avgEntry += g_position.PriceOpen();
      posCount++;
   }
   if(posCount == 0) return;
   avgEntry /= posCount;

   double price = SymbolInfoDouble(g_symbol, SYMBOL_BID);

   // Wejście pyramid: cena odeszła o krok ATR od średniej ceny
   bool pyramidLong  = (existingDir == 1  && price >= avgEntry + atrVal * InpPyramidATRStep);
   bool pyramidShort = (existingDir == -1 && price <= avgEntry - atrVal * InpPyramidATRStep);

   if(!pyramidLong && !pyramidShort) return;

   // Mniejszy lot dla pyramid
   double atrBuf[2];
   CopyBuffer(g_hATR_Main, 0, 0, 2, atrBuf);
   double sl = (existingDir == 1)
               ? price - atrBuf[1] * InpATR_SL_Mult
               : price + atrBuf[1] * InpATR_SL_Mult;
   double tp = (existingDir == 1)
               ? price + atrBuf[1] * InpATR_TP_Mult
               : price - atrBuf[1] * InpATR_TP_Mult;
   double lot = CalculateLotSize(price, sl) * 0.5; // połowa rozmiaru
   if(lot < InpMinLot) return;

   int digs = g_digits;
   sl = NormalizeDouble(sl, digs);
   tp = NormalizeDouble(tp, digs);

   bool ok = false;
   if(existingDir == 1)
      ok = g_trade.Buy(lot,  g_symbol, price, sl, tp, "PYRAMID_LONG");
   else
      ok = g_trade.Sell(lot, g_symbol, price, sl, tp, "PYRAMID_SHORT");

   if(ok) Print("[PYRAMID] Dodano pozycję #", posCount + 1, " lot:", lot);
}

//+------------------------------------------------------------------+
//|  OCHRONA KAPITAŁU                                                |
//+------------------------------------------------------------------+

void UpdateEquityProtection() {
   double equity  = g_account.Equity();
   double balance = g_account.Balance();

   // Aktualizuj peak
   if(equity > g_peakBalance) g_peakBalance = equity;

   // Max drawdown od szczytu
   double drawdownPct = (g_peakBalance - equity) / g_peakBalance * 100.0;
   if(drawdownPct >= InpMaxDrawdown) {
      CloseAllPositions("MAX_DRAWDOWN_" + DoubleToString(drawdownPct, 1) + "%");
      g_botDisabledToday = true;
      Print("[SAFETY] MAX DRAWDOWN przekroczony: ", drawdownPct, "%");
      return;
   }

   // Dzienna strata
   double dailyLoss = (g_dailyStartBalance - equity) / g_dailyStartBalance * 100.0;
   if(dailyLoss >= InpMaxDailyLoss) {
      CloseAllPositions("DAILY_LOSS_" + DoubleToString(dailyLoss, 1) + "%");
      g_botDisabledToday = true;
      Print("[SAFETY] Dzienna strata osiągnięta: ", dailyLoss, "%");
   }

   // Aktualizuj statystyki
   g_stats.currentEquity = equity;
   double dd = (g_stats.peakEquity - equity) / g_stats.peakEquity * 100.0;
   if(dd > g_stats.maxDrawdown) g_stats.maxDrawdown = dd;
}

void CloseAllPositions(string reason) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!g_position.SelectByIndex(i)) continue;
      if(g_position.Symbol() != g_symbol) continue;
      if(g_position.Magic() != g_magicBase) continue;
      g_trade.PositionClose(g_position.Ticket());
      Print("[CLOSE ALL] ", reason, " ticket:", g_position.Ticket());
   }
}

void CheckNewDay() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   MqlDateTime lastDt;
   TimeToStruct(g_lastDayCheck, lastDt);

   if(dt.day != lastDt.day) {
      g_dailyStartBalance = g_account.Balance();
      g_botDisabledToday  = false;
      g_lastDayCheck      = TimeCurrent();
      Print("[NEW DAY] Reset dzienny. Balans startowy: ", g_dailyStartBalance);
   }
}

//+------------------------------------------------------------------+
//|  KALKULACJA LOTA                                                 |
//+------------------------------------------------------------------+

double CalculateLotSize(double entry, double sl) {
   double balance       = g_account.Balance();
   double riskAmount    = balance * InpRiskPercent / 100.0;
   double slDistance    = MathAbs(entry - sl);
   if(slDistance < g_point) slDistance = g_point;

   double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0) return InpMinLot;

   double lotSize = riskAmount / (slDistance / tickSize * tickValue);
   double stepLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   lotSize = MathFloor(lotSize / stepLot) * stepLot;
   lotSize = MathMax(InpMinLot, MathMin(InpMaxLot, lotSize));
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//|  SESJA HANDLOWA                                                  |
//+------------------------------------------------------------------+

bool IsInTradingSession() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Piątek po 18:00 UTC
   if(dt.day_of_week == 5 && dt.hour >= 18 && !InpTradeFriday) return false;
   // Weekend
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   // Godziny sesji
   if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour) return false;

   return true;
}

//+------------------------------------------------------------------+
//|  STATYSTYKI BACKTESTOWE                                          |
//+------------------------------------------------------------------+

void UpdateStats_Open(TradeSignal &sig) {
   g_stats.totalTrades++;
}

void UpdateStats_Close(double profit) {
   if(profit > 0) {
      g_stats.winTrades++;
      g_stats.totalProfit += profit;
   } else {
      g_stats.lossTrades++;
      g_stats.totalLoss   += MathAbs(profit);
   }
   RecalcStats();
}

void RecalcStats() {
   int total = g_stats.winTrades + g_stats.lossTrades;
   if(total == 0) return;

   g_stats.winRate       = (double)g_stats.winTrades / total * 100.0;
   g_stats.profitFactor  = (g_stats.totalLoss > 0)
                           ? g_stats.totalProfit / g_stats.totalLoss : 0.0;
   g_stats.avgWin        = (g_stats.winTrades > 0)
                           ? g_stats.totalProfit / g_stats.winTrades : 0.0;
   g_stats.avgLoss       = (g_stats.lossTrades > 0)
                           ? g_stats.totalLoss   / g_stats.lossTrades : 0.0;
}

void LogDecision(TradeSignal &sig, bool executed, string extra) {
   if(!InpSaveStats || g_statsFileHandle == INVALID_HANDLE) return;
   RecalcStats();
   FileWrite(g_statsFileHandle,
      TimeToString(TimeCurrent()),
      g_symbol,
      sig.direction == 1 ? "BUY" : "SELL",
      DoubleToString(sig.entryPrice, g_digits),
      DoubleToString(sig.stopLoss,   g_digits),
      DoubleToString(sig.takeProfit, g_digits),
      DoubleToString(sig.lotSize, 2),
      executed ? "OPEN" : "SKIP",
      sig.reason + " | " + extra,
      DoubleToString(sig.aiScore, 2),
      DoubleToString(g_stats.winRate, 1) + "%",
      DoubleToString(g_stats.profitFactor, 2)
   );
   FileFlush(g_statsFileHandle);
}

void WriteStatsSummary() {
   if(g_statsFileHandle == INVALID_HANDLE) return;
   RecalcStats();
   FileWrite(g_statsFileHandle, "--- SUMMARY ---");
   FileWrite(g_statsFileHandle, "Total trades",   g_stats.totalTrades);
   FileWrite(g_statsFileHandle, "Win trades",     g_stats.winTrades);
   FileWrite(g_statsFileHandle, "Loss trades",    g_stats.lossTrades);
   FileWrite(g_statsFileHandle, "Win rate",       DoubleToString(g_stats.winRate, 1) + "%");
   FileWrite(g_statsFileHandle, "Total profit",   DoubleToString(g_stats.totalProfit, 2));
   FileWrite(g_statsFileHandle, "Total loss",     DoubleToString(g_stats.totalLoss, 2));
   FileWrite(g_statsFileHandle, "Profit factor",  DoubleToString(g_stats.profitFactor, 2));
   FileWrite(g_statsFileHandle, "Avg win",        DoubleToString(g_stats.avgWin, 2));
   FileWrite(g_statsFileHandle, "Avg loss",       DoubleToString(g_stats.avgLoss, 2));
   FileWrite(g_statsFileHandle, "Max drawdown",   DoubleToString(g_stats.maxDrawdown, 2) + "%");
}

//+------------------------------------------------------------------+
//|  OnTradeTransaction — śledzenie zamkniętych pozycji              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != g_symbol) return;

   HistoryDealSelect(trans.deal);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_INOUT) {
      UpdateStats_Close(profit);
      Print("[DEAL CLOSED] Profit: ", profit,
            " WinRate: ", DoubleToString(g_stats.winRate, 1), "%",
            " PF: ", DoubleToString(g_stats.profitFactor, 2));
   }
}

//+------------------------------------------------------------------+
//|  DASHBOARD — panel na wykresie                                   |
//+------------------------------------------------------------------+

void UpdateDashboard(string statusMsg) {
   RecalcStats();
   double equity  = g_account.Equity();
   double balance = g_account.Balance();
   double dailyPnL = equity - g_dailyStartBalance;

   string lines[10];
   lines[0] = "╔══ HybridAlpha2026 ══╗";
   lines[1] = StringFormat("║ Symbol : %-10s ║", g_symbol);
   lines[2] = StringFormat("║ Equity : %10.2f ║", equity);
   lines[3] = StringFormat("║ DayPnL : %+10.2f ║", dailyPnL);
   lines[4] = StringFormat("║ Pozycje: %-3d / %-3d   ║", CountOpenPositions(), InpMaxPositions);
   lines[5] = StringFormat("║ WinRate: %-6.1f%%     ║", g_stats.winRate);
   lines[6] = StringFormat("║ PFactor: %-8.2f   ║", g_stats.profitFactor);
   lines[7] = StringFormat("║ Trades : %-5d       ║", g_stats.totalTrades);
   lines[8] = statusMsg != "" ? StringFormat("║ %-20s ║", statusMsg) : "║                     ║";
   lines[9] = "╚═════════════════════╝";

   for(int i = 0; i < 10; i++) {
      string name = "HA_Panel_" + IntegerToString(i);
      if(ObjectFind(0, name) < 0) {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 15 + i * 16);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0,  name, OBJPROP_FONT, "Courier New");
      }
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);
   }
   ChartRedraw(0);
}

void CleanDashboard() {
   for(int i = 0; i < 10; i++) {
      string name = "HA_Panel_" + IntegerToString(i);
      if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//|  HELPER: liczba otwartych pozycji                                |
//+------------------------------------------------------------------+
int CountOpenPositions() {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      if(!g_position.SelectByIndex(i)) continue;
      if(g_position.Symbol() == g_symbol && g_position.Magic() == g_magicBase) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//|  MODUŁ BACKTESTOWY — wywoływany z OnTester()                    |
//+------------------------------------------------------------------+
double OnTester() {
   // Własna funkcja celu dla optymalizatora MT5
   // Łączy winrate, profit factor i max drawdown
   if(g_stats.totalTrades < 10) return 0.0; // za mało transakcji

   RecalcStats();

   double winRateScore  = g_stats.winRate / 100.0;          // 0–1 (cel: 0.70)
   double pfScore       = MathMin(g_stats.profitFactor / 3.0, 1.0); // norm do 1
   double ddPenalty     = 1.0 - (g_stats.maxDrawdown / 100.0);      // kara za DD
   double tradesBonus   = MathMin((double)g_stats.totalTrades / 100.0, 1.0);

   // Złożona funkcja celu: wyższy = lepszy
   double score = (winRateScore * 0.40)
                + (pfScore      * 0.35)
                + (ddPenalty    * 0.15)
                + (tradesBonus  * 0.10);

   Print("=== BACKTEST WYNIK ===");
   Print("Transakcji  : ", g_stats.totalTrades);
   Print("Win rate    : ", DoubleToString(g_stats.winRate, 1), "%");
   Print("Profit factor: ", DoubleToString(g_stats.profitFactor, 2));
   Print("Max drawdown: ", DoubleToString(g_stats.maxDrawdown, 2), "%");
   Print("Score (cel) : ", DoubleToString(score, 4));
   Print("======================");

   return score;
}
//+------------------------------------------------------------------+
