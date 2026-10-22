import { afterEach, describe, expect, it, vi } from 'vitest'

afterEach(() => {
  vi.unstubAllEnvs()
  vi.resetModules()
})

describe('the chain the app and its wallets talk to', () => {
  // Wallets, and the mock connector of the end-to-end runs, send transactions to the chain's own RPC rather than to
  // the app's transport. A local chain on another port must therefore be the chain's RPC too, or the page reads one
  // node while transactions go to another.
  it('sends a local chain on another port the transactions as well as the reads', async () => {
    vi.stubEnv('VITE_CHAIN_ID', '31337')
    vi.stubEnv('VITE_RPC_URL', 'http://127.0.0.1:8555')
    const { chain, rpcUrl } = await import('./chain')
    expect(rpcUrl).toBe('http://127.0.0.1:8555')
    expect(chain.rpcUrls.default.http[0]).toBe('http://127.0.0.1:8555')
  })

  it('keeps a Base Sepolia RPC override out of the chain wallets are given', async () => {
    vi.stubEnv('VITE_CHAIN_ID', '84532')
    vi.stubEnv('VITE_RPC_URL', 'https://base-sepolia.example/v2/secret-key')
    const { chain, rpcUrl } = await import('./chain')
    expect(rpcUrl).toBe('https://base-sepolia.example/v2/secret-key')
    expect(chain.rpcUrls.default.http[0]).toBe('https://sepolia.base.org')
  })
})
