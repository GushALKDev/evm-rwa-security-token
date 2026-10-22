import { useEffect, useMemo, useState } from 'react'
import { useBlock, useConnection } from 'wagmi'
import { buildModel, type TokenModel } from '../lib/model'
import { useTokenData } from './useTokenData'

/** Wall-clock seconds, ticking once a second, for countdowns. Rules are evaluated at the chain's time instead. */
export function useNow(intervalMs = 1_000): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)))
  useEffect(() => {
    const id = window.setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
  return now
}

export function useModel(): { model: TokenModel | null; error: Error | null } {
  const { address } = useConnection()
  const data = useTokenData(address)
  const now = useNow()
  // The latest block's timestamp: what the next call's simulation sees, and a floor for when it lands.
  const block = useBlock({ watch: true })
  const chainTime = block.data?.timestamp
  const model = useMemo(() => {
    if (!data.static || !data.live || !data.parties || !data.restricted || chainTime === undefined) return null
    return buildModel(data.deployment, data.static, data.live, data.parties, data.restricted, data.extras, address, chainTime, now)
  }, [data.deployment, data.static, data.live, data.parties, data.restricted, data.extras, address, chainTime, now])
  return { model, error: ((data.error ?? block.error) as Error | null) ?? null }
}
