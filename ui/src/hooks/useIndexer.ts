import { useEffect, useState, useCallback } from 'react';
import type { Address } from 'viem';

const INDEXER_URL = import.meta.env.VITE_INDEXER_URL || 'http://localhost:3001';

interface IndexerUpdate {
  type: 'update' | 'connected';
  timestamp: number;
  stats?: {
    totalBatches: number;
    totalOrders: number;
    activeUsers: number;
  };
}

interface BatchData {
  batchId: string;
  marketId: string;
  timestamp: number;
  orders: OrderData[];
  cleared: boolean;
}

interface OrderData {
  orderId: string;
  trader: Address;
  marketId: string;
  batchId: string;
  side: number;
  flow: number;
  priceTick: number;
  qty: string;
  filledQty?: string;
  timestamp: number;
  txHash: string;
}

/**
 * Hook to listen to real-time indexer updates via SSE
 */
export function useIndexerUpdates() {
  const [update, setUpdate] = useState<IndexerUpdate | null>(null);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    const eventSource = new EventSource(`${INDEXER_URL}/events`);

    eventSource.onopen = () => {
      console.log('Indexer SSE connected');
      setConnected(true);
    };

    eventSource.onmessage = (event) => {
      const data = JSON.parse(event.data) as IndexerUpdate;
      setUpdate(data);
    };

    eventSource.onerror = () => {
      console.error('Indexer SSE error');
      setConnected(false);
    };

    return () => {
      eventSource.close();
      setConnected(false);
    };
  }, []);

  return { update, connected };
}

/**
 * Hook to fetch recent batches
 */
export function useRecentBatches(marketId?: string, limit = 10) {
  const [batches, setBatches] = useState<BatchData[]>([]);
  const [loading, setLoading] = useState(true);
  const { update } = useIndexerUpdates();

  const fetchBatches = useCallback(async () => {
    try {
      const params = new URLSearchParams({
        limit: limit.toString(),
        ...(marketId && { marketId }),
      });
      const res = await fetch(`${INDEXER_URL}/batches?${params}`);
      const data = await res.json();
      setBatches(data.batches);
    } catch (error) {
      console.error('Error fetching batches:', error);
    } finally {
      setLoading(false);
    }
  }, [marketId, limit]);

  useEffect(() => {
    fetchBatches();
  }, [fetchBatches]);

  // Refetch on updates
  useEffect(() => {
    if (update?.type === 'update') {
      fetchBatches();
    }
  }, [update, fetchBatches]);

  return { batches, loading, refetch: fetchBatches };
}

/**
 * Hook to fetch user orders
 */
export function useUserOrders(address?: Address) {
  const [orders, setOrders] = useState<OrderData[]>([]);
  const [loading, setLoading] = useState(true);
  const { update } = useIndexerUpdates();

  const fetchOrders = useCallback(async () => {
    if (!address) {
      setOrders([]);
      setLoading(false);
      return;
    }

    try {
      const res = await fetch(`${INDEXER_URL}/orders/user/${address.toLowerCase()}`);
      const data = await res.json();
      setOrders(data.orders || []);
    } catch (error) {
      console.error('Error fetching user orders:', error);
    } finally {
      setLoading(false);
    }
  }, [address]);

  useEffect(() => {
    fetchOrders();
  }, [fetchOrders]);

  // Refetch on updates
  useEffect(() => {
    if (update?.type === 'update') {
      fetchOrders();
    }
  }, [update, fetchOrders]);

  return { orders, loading, refetch: fetchOrders };
}

/**
 * Hook to fetch specific batch
 */
export function useBatch(marketId?: string, batchId?: string) {
  const [batch, setBatch] = useState<BatchData | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!marketId || !batchId) {
      setBatch(null);
      setLoading(false);
      return;
    }

    async function fetchBatch() {
      try {
        const res = await fetch(`${INDEXER_URL}/batch/${marketId}/${batchId}`);
        if (res.ok) {
          const data = await res.json();
          setBatch(data);
        } else {
          setBatch(null);
        }
      } catch (error) {
        console.error('Error fetching batch:', error);
      } finally {
        setLoading(false);
      }
    }

    fetchBatch();
  }, [marketId, batchId]);

  return { batch, loading };
}

/**
 * Hook to fetch specific order
 */
export function useIndexerOrder(orderId?: string) {
  const [order, setOrder] = useState<OrderData | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!orderId) {
      setOrder(null);
      setLoading(false);
      return;
    }

    async function fetchOrder() {
      try {
        const res = await fetch(`${INDEXER_URL}/order/${orderId}`);
        if (res.ok) {
          const data = await res.json();
          setOrder(data);
        } else {
          setOrder(null);
        }
      } catch (error) {
        console.error('Error fetching order:', error);
      } finally {
        setLoading(false);
      }
    }

    fetchOrder();
  }, [orderId]);

  return { order, loading };
}

/**
 * Hook to fetch indexer stats
 */
export function useIndexerStats() {
  const [stats, setStats] = useState({
    totalBatches: 0,
    totalOrders: 0,
    activeUsers: 0,
  });
  const { update } = useIndexerUpdates();

  useEffect(() => {
    async function fetchStats() {
      try {
        const res = await fetch(`${INDEXER_URL}/stats`);
        const data = await res.json();
        setStats(data);
      } catch (error) {
        console.error('Error fetching stats:', error);
      }
    }

    fetchStats();
  }, []);

  // Update from SSE
  useEffect(() => {
    if (update?.stats) {
      setStats(update.stats);
    }
  }, [update]);

  return stats;
}
