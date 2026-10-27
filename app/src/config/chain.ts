import { defineChain, type Chain } from 'viem'
import { baseSepolia } from 'viem/chains'
import { loadDeployment } from './deployment'

const LOCAL_CHAIN_ID = 31_337

export const chainId = Number(import.meta.env.VITE_CHAIN_ID ?? baseSepolia.id)

const rpcOverride: string | undefined = import.meta.env.VITE_RPC_URL || undefined

// Wallets, and the mock connector of the end-to-end runs, send transactions to the chain's own RPC, not to the
// app's transport. On a local chain the override is therefore the chain's RPC too, or a node on another port would
// get the reads and not the transactions. On Base Sepolia it stays with the transport, so a provider key in it
// never reaches a wallet's network list.
export const chain: Chain =
  chainId === LOCAL_CHAIN_ID
    ? defineChain({
        id: LOCAL_CHAIN_ID,
        name: 'Local anvil',
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: { default: { http: [rpcOverride ?? 'http://127.0.0.1:8545'] } },
      })
    : baseSepolia

export const rpcUrl: string = rpcOverride ?? chain.rpcUrls.default.http[0]

export const deployment = loadDeployment(chain.id)

export const explorer = chain.blockExplorers?.default.url

export const links = {
  repo: 'https://github.com/GushALKDev/evm-rwa-security-token',
  docs: 'https://github.com/GushALKDev/evm-rwa-security-token/blob/main/docs/README.md',
  terms: 'https://github.com/GushALKDev/evm-rwa-security-token/blob/main/docs/RealEstateNote-Terms.md',
  author: 'https://www.linkedin.com/in/gustavomaral/',
  tesselium: 'https://tesselium.com',
  ethFaucet: 'https://docs.base.org/get-started/get-funds',
}

export function explorerAddress(address: string) {
  return explorer ? `${explorer}/address/${address}` : undefined
}

export function explorerTx(hash: string) {
  return explorer ? `${explorer}/tx/${hash}` : undefined
}
