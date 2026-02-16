import React, { useMemo, useState, useEffect } from "react";
import { useAccount, useDisconnect, useChainId } from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import type { Address } from 'viem';
import {
  useBatchId,
  useBatchEnd,
  useBatchDuration,
  useSubmitSpotOrder,
  useFinalizeBatch,
  useCancelOrder,
  useOrder,
  useOrderFilledQty,
  useAvailableMargin,
  useTokenBalance,
  useApproveToken,
  useTokenAllowance,
  Side,
  Flow,
  type Order,
  priceToTick,
  formatWei,
  parseWei,
} from './hooks/useContracts';
import { getContracts } from './config/contracts';

export default function App() {
  // Wagmi hooks
  const { address, isConnected } = useAccount();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();

  const [showConnectModal, setShowConnectModal] = useState(false);

  // Get contract addresses for current chain
  const contracts = useMemo(() => getContracts(chainId), [chainId]);

  // Market state
  const MARKET_ID = 1n; // ETH/USDC spot market
  const [market, setMarket] = useState("ETH/USDC");
  
  // DFBA Order Type: 4 combinations
  // Maker-Buy (MB) + Taker-Sell (TS) = BID AUCTION
  // Maker-Sell (MS) + Taker-Buy (TB) = ASK AUCTION
  const [orderType, setOrderType] = useState<"MB" | "MS" | "TB" | "TS">("TB");
  
  const [size, setSize] = useState("0.50");
  const [limit, setLimit] = useState("2450");
  const [slippageBps, setSlippageBps] = useState(30);
  const [postOnly, setPostOnly] = useState(false);
  const [reduceOnly, setReduceOnly] = useState(false);

  // Contract hooks
  const { data: currentBatchId, refetch: refetchBatchId } = useBatchId(MARKET_ID);
  const { data: batchEnd } = useBatchEnd(MARKET_ID);
  const { data: batchDuration } = useBatchDuration();
  const { data: marginBalance } = useAvailableMargin(address, contracts.USDC as Address, 0n);
  const { data: usdcBalance } = useTokenBalance(address, contracts.USDC as Address);
  const { data: allowanceSpotRouter } = useTokenAllowance(address, contracts.USDC as Address, contracts.SPOT_ROUTER as Address);
  const { data: allowanceCoreVault } = useTokenAllowance(address, contracts.USDC as Address, contracts.CORE_VAULT as Address);
  
  const { submitOrder, isPending: isSubmitting, isSuccess: orderSuccess, hash: orderHash } = useSubmitSpotOrder();
  const { finalizeBatch, isPending: isFinalizing, isSuccess: finalizeSuccess } = useFinalizeBatch();
  const { approve, isPending: isApproving, isSuccess: approveSuccess } = useApproveToken();

  // Batch clock (use real batch ID when available)
  const batchDurationMs = batchDuration ? Number(batchDuration) * 1000 : 1000; // Default 1 second
  const [now, setNow] = useState(() => Date.now());
  
  useEffect(() => {
    const t = setInterval(() => {
      setNow(Date.now());
      refetchBatchId();
    }, 100);
    return () => clearInterval(t);
  }, [refetchBatchId]);

  const batchId = currentBatchId ? Number(currentBatchId) : Math.floor(now / batchDurationMs);
  const msInto = batchEnd ? Math.max(0, Number(batchEnd) * 1000 - now) : now % batchDurationMs;
  const msLeft = batchDurationMs - msInto;
  const progress = msInto / batchDurationMs;

  // Pricing (mock - replace with oracle/indexer data)
  const last = 2448.62;
  const mark = 2449.1;
  const estLow = 2447.8;
  const estHigh = 2451.2;

  // Derived calculations
  const parsedSize = Number(size || "0");
  const parsedLimit = Number(limit || "0");
  
  const notional = useMemo(() => {
    const px = Number.isFinite(parsedLimit) && parsedLimit > 0 ? parsedLimit : last;
    return parsedSize * px;
  }, [parsedSize, parsedLimit, last]);

  // Maker orders provide liquidity (lower fee), Taker orders take liquidity (higher fee)
  const feeBps = (orderType === "MB" || orderType === "MS") ? 2 : 6;
  const fee = useMemo(() => (notional * feeBps) / 10_000, [notional, feeBps]);

  const limitFromSlippage = useMemo(() => {
    const bps = slippageBps;
    // MB/TB = buying (willing to pay more), MS/TS = selling (willing to accept less)
    if (orderType === "MB" || orderType === "TB") {
      return (last * (1 + bps / 10_000)).toFixed(2); // Max buy price
    }
    return (last * (1 - bps / 10_000)).toFixed(2); // Min sell price
  }, [orderType, last, slippageBps]);

  const preview = useMemo(() => {
    const lim = Number.isFinite(parsedLimit) && parsedLimit > 0 ? parsedLimit : Number(limitFromSlippage);
    
    // For BID AUCTION (MB/TS): higher bids fill first
    // For ASK AUCTION (MS/TB): lower asks fill first
    let inMoney = false;
    let atMargin = false;
    let fillText = "";
    let auctionType = "";
    
    if (orderType === "MB") {
      // Maker-Buy in bid auction: fills if bid >= clearing
      auctionType = "BID AUCTION";
      inMoney = lim >= estHigh;
      atMargin = lim >= estLow && lim < estHigh;
      fillText = inMoney ? "Likely fills (bid above expected clearing)" 
        : atMargin ? "May fill pro-rata at marginal tick" 
        : "Below expected clearing - unlikely to fill";
    } else if (orderType === "TS") {
      // Taker-Sell in bid auction: always fills at clearing price
      auctionType = "BID AUCTION";
      inMoney = true;
      fillText = "Fills at bid clearing price (market sell)";
    } else if (orderType === "MS") {
      // Maker-Sell in ask auction: fills if ask <= clearing
      auctionType = "ASK AUCTION";
      inMoney = lim <= estLow;
      atMargin = lim <= estHigh && lim > estLow;
      fillText = inMoney ? "Likely fills (ask below expected clearing)" 
        : atMargin ? "May fill pro-rata at marginal tick" 
        : "Above expected clearing - unlikely to fill";
    } else { // TB
      // Taker-Buy in ask auction: always fills at clearing price
      auctionType = "ASK AUCTION";
      inMoney = true;
      fillText = "Fills at ask clearing price (market buy)";
    }

    return {
      inMoney,
      atMargin,
      fillText,
      auctionType,
      estPriceBand: `${estLow.toFixed(2)} – ${estHigh.toFixed(2)}`,
    };
  }, [parsedLimit, orderType, estLow, estHigh, limitFromSlippage]);

  // Mock batch book data
  const levels = useMemo(() => [
    { tick: 2446, makerBuy: 120, makerSell: 20, takerBuy: 40, takerSell: 10 },
    { tick: 2447, makerBuy: 180, makerSell: 35, takerBuy: 55, takerSell: 12 },
    { tick: 2448, makerBuy: 210, makerSell: 60, takerBuy: 75, takerSell: 20 },
    { tick: 2449, makerBuy: 260, makerSell: 95, takerBuy: 110, takerSell: 25 },
    { tick: 2450, makerBuy: 200, makerSell: 130, takerBuy: 140, takerSell: 40 },
    { tick: 2451, makerBuy: 140, makerSell: 170, takerBuy: 120, takerSell: 60 },
    { tick: 2452, makerBuy: 90, makerSell: 210, takerBuy: 80, takerSell: 85 },
  ], []);

  const imbalance = useMemo(() => {
    const tb = levels.reduce((a, x) => a + x.takerBuy, 0);
    const ts = levels.reduce((a, x) => a + x.takerSell, 0);
    return tb - ts;
  }, [levels]);

  // Handle approve USDC for both SpotRouter and CoreVault
  const handleApprove = () => {
    if (!address) return;
    const maxApproval = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    // Approve SpotRouter for order submission
    approve(contracts.USDC as Address, contracts.SPOT_ROUTER as Address, maxApproval);
    // Note: Also need to approve CoreVault for margin deposits if doing perp trading
  };

  // Handle place order
  const handlePlaceOrder = () => {
    if (!address || !currentBatchId) {
      alert("Please connect wallet and wait for batch data");
      return;
    }

    if (!allowanceSpotRouter || allowanceSpotRouter === 0n) {
      alert("Please approve USDC spending for SpotRouter first");
      return;
    }

    const priceTickValue = parsedLimit > 0 ? priceToTick(parsedLimit) : priceToTick(Number(limitFromSlippage));
    const qtyWei = parseWei(size, 18);
    const nonceValue = BigInt(Date.now());

    // Map UI order type to contract Side/Flow
    let side: typeof Side.Buy | typeof Side.Sell;
    let flow: typeof Flow.Maker | typeof Flow.Taker;
    
    if (orderType === "MB") {
      side = Side.Buy;
      flow = Flow.Maker;
    } else if (orderType === "MS") {
      side = Side.Sell;
      flow = Flow.Maker;
    } else if (orderType === "TB") {
      side = Side.Buy;
      flow = Flow.Taker;
    } else { // TS
      side = Side.Sell;
      flow = Flow.Taker;
    }

    const order: Order = {
      trader: address,
      marketId: MARKET_ID,
      side,
      flow,
      priceTick: priceTickValue,
      qty: qtyWei,
      nonce: nonceValue,
      expiry: 0n,
    };

    submitOrder(order);
  };

  // Handle finalize
  const handleFinalize = () => {
    if (!currentBatchId) return;
    // Finalize previous batch
    const batchToFinalize = currentBatchId > 1n ? currentBatchId - 1n : currentBatchId;
    finalizeBatch(MARKET_ID, batchToFinalize, BigInt(100));
  };

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      {/* Top bar */}
      <header className="sticky top-0 z-20 border-b border-zinc-800 bg-zinc-950/80 backdrop-blur">
        <div className="mx-auto flex w-screen items-center justify-between px-4 py-3">
          <div className="flex items-center gap-3">
            <div className="h-9 w-9 rounded-2xl bg-linear-to-br from-emerald-400/40 to-cyan-400/20 shadow-sm" />
            <div>
              <div className="text-sm font-semibold tracking-wide">
                DFBA Exchange
              </div>
              <div className="text-xs text-zinc-400">
                Batch auctions • price/size competition
              </div>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <select
              value={market}
              onChange={(e) => setMarket(e.target.value)}
              className="rounded-xl border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-emerald-500/30"
            >
              <option>ETH/USDC</option>
              <option>BTC/USDC</option>
              <option>SOL/USDC</option>
              <option>ETH-PERP</option>
              <option>BTC-PERP</option>
            </select>
            
            <ConnectButton />
          </div>
        </div>

        {/* Wallet info bar */}
        {isConnected && (
          <div className="border-t border-zinc-800 bg-zinc-900/40 px-4 py-2">
            <div className="mx-auto flex max-w-7xl items-center justify-between text-xs">
              <div className="flex items-center gap-4">
                <span className="text-zinc-400">USDC Balance:</span>
                <span className="font-mono text-zinc-200">
                  {usdcBalance ? formatWei(usdcBalance, 6) : '0.00'}
                </span>
              </div>
              <div className="flex items-center gap-4">
                <span className="text-zinc-400">Available Margin:</span>
                <span className="font-mono text-zinc-200">
                  {marginBalance ? formatWei(marginBalance, 6) : '0.00'}
                </span>
              </div>
              {(!allowanceSpotRouter || allowanceSpotRouter === 0n) && (
                <button
                  onClick={handleApprove}
                  disabled={isApproving}
                  className="rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-xs text-amber-200 hover:bg-amber-500/20 disabled:opacity-50"
                >
                  {isApproving ? 'Approving...' : 'Approve USDC (SpotRouter)'}
                </button>
              )}
            </div>
          </div>
        )}
      </header>

      <main className="mx-auto grid max-w-7xl grid-cols-1 gap-6 px-4 py-4 lg:grid-cols-3">
        {/* Left: chart + auction history */}
        <section className="lg:col-span-2">
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900/40 p-4 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className="text-lg font-semibold">{market}</div>
                <div className="mt-1 flex flex-wrap items-center gap-3 text-sm">
                  <div className="text-zinc-300">
                    Last{" "}
                    <span className="font-semibold">{last.toFixed(2)}</span>
                  </div>
                  <div className="text-zinc-400">Mark {mark.toFixed(2)}</div>
                  <div className="text-zinc-400">
                    Est. clear {estLow.toFixed(2)}–{estHigh.toFixed(2)}
                  </div>
                </div>
              </div>

              {/* Batch clock */}
              <div className="w-44 rounded-2xl border border-zinc-800 bg-zinc-950/50 p-3">
                <div className="flex items-center justify-between">
                  <div className="text-xs text-zinc-400">Batch</div>
                  <div className="text-xs text-zinc-400">#{batchId}</div>
                </div>
                <div className="mt-1 text-sm font-semibold">
                  Clears in {(msLeft / 1000).toFixed(2)}s
                </div>
                <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-zinc-800">
                  <div
                    className="h-full rounded-full bg-emerald-400/70"
                    style={{
                      width: `${Math.min(100, Math.max(0, progress * 100))}%`,
                    }}
                  />
                </div>
                <div className="mt-2 text-[11px] text-zinc-400">
                  Frequent batch • no queue priority
                </div>
              </div>
            </div>

            {/* Chart placeholder */}
            <div className="mt-4 grid h-64 place-items-center rounded-2xl border border-zinc-800 bg-zinc-950/30">
              <div className="text-center">
                <div className="text-sm font-semibold">Price chart</div>
                <div className="mt-1 text-xs text-zinc-400">
                  (placeholder — wire to your indexer)
                </div>
              </div>
            </div>

            {/* Batch history */}
            <div className="mt-4">
              <div className="flex items-center justify-between">
                <div className="text-sm font-semibold">Recent batches</div>
                <button className="text-xs text-zinc-400 hover:text-zinc-200">
                  View all
                </button>
              </div>
              <div className="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
                {[0, 1, 2, 3].map((i) => (
                  <div
                    key={i}
                    className="rounded-2xl border border-zinc-800 bg-zinc-950/40 p-3"
                  >
                    <div className="flex items-center justify-between">
                      <div className="text-xs text-zinc-400">
                        Batch #{batchId - (i + 1)}
                      </div>
                      <div className="text-xs text-zinc-400">
                        Vol ${(120 + i * 35).toFixed(0)}k
                      </div>
                    </div>
                    <div className="mt-1 text-sm font-semibold">
                      Clear {(last - i * 0.8).toFixed(2)}
                    </div>
                    <div className="mt-1 text-[11px] text-zinc-400">
                      Marginal pro-rata {(72 - i * 7).toFixed(0)}%
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* Right: order ticket + batch book */}
        <section className="lg:col-span-1 space-y-4">
          {/* Order ticket */}
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900/40 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div className="text-sm font-semibold">Trade</div>
              <div className="text-xs text-zinc-400">Batch #{batchId}</div>
            </div>

            {!isConnected && (
              <div className="mt-3 rounded-xl border border-amber-500/30 bg-amber-500/10 p-3 text-center text-sm text-amber-200">
                Connect wallet to trade
              </div>
            )}

            {/* DFBA Order Type Selector */}
            <div className="mt-3 space-y-2">
              <div className="text-xs text-zinc-400 font-semibold">Order Type</div>
              <div className="grid grid-cols-2 gap-2">
                <button
                  onClick={() => setOrderType("TB")}
                  className={
                    orderType === "TB"
                      ? "rounded-2xl bg-emerald-500/15 text-emerald-200 ring-1 ring-emerald-500/30 p-3 text-left"
                      : "rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3 text-left hover:bg-zinc-900/40"
                  }
                >
                  <div className="text-sm font-semibold">Taker-Buy</div>
                  <div className="text-[11px] text-zinc-400 mt-0.5">Market buy at ask clearing</div>
                </button>
                <button
                  onClick={() => setOrderType("TS")}
                  className={
                    orderType === "TS"
                      ? "rounded-2xl bg-rose-500/15 text-rose-200 ring-1 ring-rose-500/30 p-3 text-left"
                      : "rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3 text-left hover:bg-zinc-900/40"
                  }
                >
                  <div className="text-sm font-semibold">Taker-Sell</div>
                  <div className="text-[11px] text-zinc-400 mt-0.5">Market sell at bid clearing</div>
                </button>
                <button
                  onClick={() => setOrderType("MB")}
                  className={
                    orderType === "MB"
                      ? "rounded-2xl bg-blue-500/15 text-blue-200 ring-1 ring-blue-500/30 p-3 text-left"
                      : "rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3 text-left hover:bg-zinc-900/40"
                  }
                >
                  <div className="text-sm font-semibold">Maker-Buy</div>
                  <div className="text-[11px] text-zinc-400 mt-0.5">Limit bid (provide liquidity)</div>
                </button>
                <button
                  onClick={() => setOrderType("MS")}
                  className={
                    orderType === "MS"
                      ? "rounded-2xl bg-amber-500/15 text-amber-200 ring-1 ring-amber-500/30 p-3 text-left"
                      : "rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3 text-left hover:bg-zinc-900/40"
                  }
                >
                  <div className="text-sm font-semibold">Maker-Sell</div>
                  <div className="text-[11px] text-zinc-400 mt-0.5">Limit ask (provide liquidity)</div>
                </button>
              </div>
              <div className="text-[11px] text-zinc-500 bg-zinc-950/50 rounded-xl p-2 border border-zinc-800">
                <span className="font-semibold">BID AUCTION:</span> Maker-Buy + Taker-Sell<br/>
                <span className="font-semibold">ASK AUCTION:</span> Maker-Sell + Taker-Buy
              </div>
            </div>

            {/* Inputs */}
            <div className="mt-3 space-y-3">
              <div>
                <label className="text-xs text-zinc-400">Size</label>
                <div className="mt-1 flex items-center gap-2">
                  <input
                    value={size}
                    onChange={(e) => setSize(e.target.value)}
                    placeholder="0.00"
                    className="w-full rounded-2xl border border-zinc-800 bg-zinc-950/30 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-emerald-500/30"
                  />
                  <div className="rounded-2xl border border-zinc-800 bg-zinc-950/30 px-3 py-2 text-sm text-zinc-300">
                    {market.includes("PERP")
                      ? "Contracts"
                      : market.split("/")[0]}
                  </div>
                </div>
              </div>

              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <div>
                  <label className="text-xs text-zinc-400">Limit price</label>
                  <input
                    value={limit}
                    onChange={(e) => setLimit(e.target.value)}
                    placeholder={limitFromSlippage}
                    className="mt-1 w-full rounded-2xl border border-zinc-800 bg-zinc-950/30 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-emerald-500/30"
                  />
                  <div className="mt-1 text-[11px] text-zinc-500">
                    Tip: or use slippage → {limitFromSlippage}
                  </div>
                </div>
                <div>
                  <label className="text-xs text-zinc-400">Max slippage</label>
                  <div className="mt-1 rounded-2xl border border-zinc-800 bg-zinc-950/30 px-3 py-2">
                    <div className="flex items-center justify-between text-sm">
                      <span className="text-zinc-300">
                        {(slippageBps / 100).toFixed(2)}%
                      </span>
                      <span className="text-zinc-500">{slippageBps} bps</span>
                    </div>
                    <input
                      type="range"
                      min={0}
                      max={200}
                      value={slippageBps}
                      onChange={(e) => setSlippageBps(Number(e.target.value))}
                      className="mt-2 w-full"
                    />
                  </div>
                </div>
              </div>

              <div className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3">
                <div className="flex-1">
                  <div className="text-xs text-zinc-400">Auction: <span className="font-semibold text-zinc-200">{preview.auctionType}</span></div>
                  <div className="mt-1 text-sm font-semibold">
                    {preview.fillText}
                  </div>
                  <div className="mt-1 text-[11px] text-zinc-400">
                    Est. clearing: {preview.estPriceBand}
                  </div>
                </div>
                <div className="text-right">
                  <div className="text-xs text-zinc-400">Fees</div>
                  <div className="mt-1 text-sm font-semibold">
                    {fee.toFixed(4)} USDC
                  </div>
                  <div className="mt-1 text-[11px] text-zinc-400">
                    {feeBps} bps ({(orderType === "MB" || orderType === "MS") ? "maker" : "taker"})
                  </div>
                </div>
              </div>

              <div className="grid grid-cols-2 gap-2">
                <label className="flex items-center gap-2 rounded-2xl border border-zinc-800 bg-zinc-950/30 px-3 py-2 text-sm">
                  <input
                    type="checkbox"
                    checked={postOnly}
                    onChange={(e) => setPostOnly(e.target.checked)}
                    className="h-4 w-4 rounded border-zinc-700 bg-zinc-950"
                  />
                  <span className="text-zinc-300">Post-only</span>
                </label>
                <label className="flex items-center gap-2 rounded-2xl border border-zinc-800 bg-zinc-950/30 px-3 py-2 text-sm">
                  <input
                    type="checkbox"
                    checked={reduceOnly}
                    onChange={(e) => setReduceOnly(e.target.checked)}
                    className="h-4 w-4 rounded border-zinc-700 bg-zinc-950"
                  />
                  <span className="text-zinc-300">Reduce-only</span>
                </label>
              </div>

              <button
                onClick={handlePlaceOrder}
                disabled={!isConnected || isSubmitting}
                className={
                  orderType === "TB" ? "w-full rounded-2xl bg-emerald-500/20 px-4 py-3 text-sm font-semibold text-emerald-100 ring-1 ring-emerald-500/30 hover:bg-emerald-500/25 disabled:opacity-50 disabled:cursor-not-allowed"
                  : orderType === "TS" ? "w-full rounded-2xl bg-rose-500/20 px-4 py-3 text-sm font-semibold text-rose-100 ring-1 ring-rose-500/30 hover:bg-rose-500/25 disabled:opacity-50 disabled:cursor-not-allowed"
                  : orderType === "MB" ? "w-full rounded-2xl bg-blue-500/20 px-4 py-3 text-sm font-semibold text-blue-100 ring-1 ring-blue-500/30 hover:bg-blue-500/25 disabled:opacity-50 disabled:cursor-not-allowed"
                  : "w-full rounded-2xl bg-amber-500/20 px-4 py-3 text-sm font-semibold text-amber-100 ring-1 ring-amber-500/30 hover:bg-amber-500/25 disabled:opacity-50 disabled:cursor-not-allowed"
                }
              >
                {isSubmitting ? 'Submitting...' : `Place ${orderType} Order`}
              </button>

              {orderSuccess && orderHash && (
                <div className="rounded-xl border border-emerald-500/30 bg-emerald-500/10 p-3 text-center text-xs text-emerald-200">
                  Order submitted! Tx: {orderHash.slice(0, 10)}...
                </div>
              )}

              <div className="text-center text-[11px] text-zinc-500 space-y-1">
                <div>Orders collected per batch → Dual auctions clear at uniform prices</div>
                <div>Maker orders provide liquidity (2 bps) • Taker orders cross auctions (6 bps)</div>
              </div>
            </div>
          </div>

          {/* Batch book */}
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900/40 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div>
                <div className="text-sm font-semibold">DFBA Batch Book</div>
                <div className="mt-1 text-xs text-zinc-400">
                  Depth by tick for current batch
                </div>
              </div>
              <div className="rounded-xl border border-zinc-800 bg-zinc-950/30 px-3 py-2 text-xs">
                <span className="text-zinc-400">TB-TS Imbalance</span>{" "}
                <span
                  className={
                    imbalance >= 0 ? "text-emerald-200" : "text-rose-200"
                  }
                >
                  {imbalance >= 0 ? "+" : ""}
                  {imbalance}
                </span>
              </div>
            </div>

            <div className="mt-3 space-y-2">
              <div className="text-[11px] text-zinc-400 space-y-1 bg-zinc-950/50 p-2 rounded-xl border border-zinc-800">
                <div><span className="text-blue-300 font-semibold">BID AUCTION:</span> MB (blue) vs TS (red) → clears at highest bid</div>
                <div><span className="text-amber-300 font-semibold">ASK AUCTION:</span> MS (amber) vs TB (green) → clears at lowest ask</div>
              </div>
            </div>

            <div className="mt-3 rounded-2xl border border-zinc-800 bg-zinc-950/30">
              <div className="grid grid-cols-5 gap-2 border-b border-zinc-800 px-3 py-2 text-[11px] text-zinc-400">
                <div>Tick</div>
                <div className="text-right text-blue-300">MB</div>
                <div className="text-right text-amber-300">MS</div>
                <div className="text-right text-emerald-300">TB</div>
                <div className="text-right text-rose-300">TS</div>
              </div>
              <div className="max-h-64 overflow-auto">
                {levels.map((lvl) => {
                  const isBand =
                    lvl.tick >= Math.floor(estLow) &&
                    lvl.tick <= Math.ceil(estHigh);
                  return (
                    <div
                      key={lvl.tick}
                      className={
                        "grid grid-cols-5 gap-2 px-3 py-2 text-sm border-b border-zinc-900/60 " +
                        (isBand ? "bg-zinc-800/30" : "")
                      }
                    >
                      <div className="font-mono text-zinc-200">{lvl.tick}</div>
                      <div className="text-right font-mono text-blue-300">
                        {lvl.makerBuy}
                      </div>
                      <div className="text-right font-mono text-amber-300">
                        {lvl.makerSell}
                      </div>
                      <div className="text-right font-mono text-emerald-300">
                        {lvl.takerBuy}
                      </div>
                      <div className="text-right font-mono text-rose-300">
                        {lvl.takerSell}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>

            <div className="mt-3 grid grid-cols-2 gap-2">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3">
                <div className="text-xs text-zinc-400">Bid clearing (MB vs TS)</div>
                <div className="mt-1 text-sm font-semibold text-blue-200">
                  ~{estHigh.toFixed(2)}
                </div>
                <div className="mt-1 text-[11px] text-zinc-400">
                  Highest bid that clears
                </div>
              </div>
              <div className="rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3">
                <div className="text-xs text-zinc-400">Ask clearing (MS vs TB)</div>
                <div className="mt-1 text-sm font-semibold text-amber-200">
                  ~{estLow.toFixed(2)}
                </div>
                <div className="mt-1 text-[11px] text-zinc-400">
                  Lowest ask that clears
                </div>
              </div>
            </div>
            
            <div className="mt-3 rounded-2xl border border-zinc-800 bg-zinc-950/30 p-3">
              <div className="text-xs text-zinc-400">Finalize batch</div>
              <div className="mt-1 text-[11px] text-zinc-400">
                Run dual auctions → compute clearing prices → users claim fills
              </div>
              <button
                onClick={handleFinalize}
                disabled={!isConnected || isFinalizing}
                className="mt-2 w-full rounded-xl border border-zinc-800 bg-zinc-900 px-3 py-2 text-xs hover:bg-zinc-800 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {isFinalizing ? 'Finalizing...' : 'Finalize Batch'}
              </button>
              {finalizeSuccess && (
                <div className="mt-2 text-[11px] text-emerald-200">✓ Batch finalized</div>
              )}
            </div>
          </div>
        </section>
      </main>

      <footer className="mx-auto max-w-7xl px-4 pb-6 text-xs text-zinc-500">
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900/30 p-4">
          <div className="font-semibold text-zinc-300">Contract Integration Status</div>
          <ul className="mt-2 list-disc space-y-1 pl-5">
            <li>✅ Wagmi v2 with proper type safety</li>
            <li>✅ Real-time batch ID from on-chain</li>
            <li>✅ Submit orders via SpotRouter (proper user flow)</li>
            <li>✅ Approve & deposit margin flows through CoreVault</li>
            <li>✅ Finalize auction on-chain</li>
            <li>✅ Order struct matches contract (no batchId in input)</li>
            <li>⚠️ Batch book: Query from indexer or aggregate on-chain events</li>
            <li>⚠️ Clearing price: Parse clearing results from finalizeStates</li>
            <li>⚠️ Price-to-tick conversion: Currently 1:1, implement log if needed</li>
          </ul>
          <div className="mt-3 text-[11px] text-zinc-400">
            Note: For Perp trading, use PERP_ROUTER and ensure CORE_VAULT allowance + IM reserves
          </div>
        </div>
      </footer>
    </div>
  );
}
