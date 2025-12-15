import { useConnect, useAccount } from 'wagmi'

export function ConnectButton() {
  const { connectors, connect, isPending } = useConnect()
  const { isConnected } = useAccount()

  if (isConnected) return null

  return (
    <div className="flex flex-col gap-2">
      {connectors.map((connector) => (
        <button
          key={connector.uid}
          onClick={() => connect({ connector })}
          disabled={isPending}
          className="rounded-xl border border-zinc-800 bg-emerald-500/20 px-3 py-2 text-sm ring-1 ring-emerald-500/30 hover:bg-emerald-500/25 disabled:opacity-50"
        >
          {connector.name}
        </button>
      ))}
    </div>
  )
}
