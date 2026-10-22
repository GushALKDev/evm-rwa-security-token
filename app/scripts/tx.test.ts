// The app's write path (src/lib/tx.ts) against a local chain: which network a call is sent on, and how each
// outcome of a sent transaction is reported. Run after ./scripts/local-chain.sh:
//   LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/tx.test.ts
// It starts a second anvil, on chain id 8453, to stand for the network a wallet happens to be on.
import { spawn, type ChildProcess } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { BaseError, ChainMismatchError, createPublicClient, createWalletClient, defineChain, http, type Address, type Hex } from 'viem'
import { foundry } from 'viem/chains'
import { createConfig } from 'wagmi'
import { connect } from 'wagmi/actions'
import { mock } from 'wagmi/connectors'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { deskCallAbi } from '../src/lib/abi'
import { prepareCall, sendCall, waitForOutcome } from '../src/lib/tx'

const rpc = process.env.LOCAL_RPC
// The clients are built while the suite is collected, which happens even when it is skipped.
const url = rpc ?? 'http://127.0.0.1:8545'
// anvil's default accounts 7 and 8, unlocked and unused by the parity suite.
const walletOwner = '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955' as Address
const sender = '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f' as Address
const WRONG_PORT = 18_453

describe.skipIf(!rpc)('the write path on a local chain', () => {
  let d: { desk: Address }
  let snapshot: Hex
  let wrongNode: ChildProcess
  const wrongRpc = `http://127.0.0.1:${WRONG_PORT}`
  const local = defineChain({ ...foundry, rpcUrls: { default: { http: [url] } } })
  const wrong = defineChain({ ...foundry, id: 8453, name: 'Another network', rpcUrls: { default: { http: [wrongRpc] } } })
  const pub = createPublicClient({ chain: local, transport: http(url) })
  const wrongPub = createPublicClient({ chain: wrong, transport: http(wrongRpc) })
  const wallet = createWalletClient({ chain: local, transport: http(url) })

  const config = () =>
    createConfig({
      chains: [local, wrong],
      connectors: [mock({ accounts: [walletOwner] })],
      transports: { [local.id]: http(url), [wrong.id]: http(wrongRpc) },
      pollingInterval: 250,
    })

  beforeAll(async () => {
    d = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
    snapshot = await pub.request({ method: 'evm_snapshot' as never })
    wrongNode = spawn('anvil', ['--silent', '--chain-id', '8453', '--port', String(WRONG_PORT)], { stdio: 'ignore' })
    for (let i = 0; i < 50; i++) {
      try {
        await wrongPub.getChainId()
        break
      } catch {
        await new Promise((r) => setTimeout(r, 200))
      }
    }
  })

  afterAll(async () => {
    wrongNode?.kill()
    await pub.request({ method: 'evm_setAutomine' as never, params: [true] as never })
    if (snapshot) await pub.request({ method: 'evm_revert' as never, params: [snapshot] as never })
  })

  it('refuses to send on the network the wallet is on when it is not the app chain', async () => {
    const c = config()
    await connect(c, { connector: c.connectors[0], chainId: wrong.id })
    const call = { address: d.desk, abi: deskCallAbi, functionName: 'onboard', args: [724] }
    const before = await wrongPub.getTransactionCount({ address: walletOwner })

    const prepared = await prepareCall(c, local.id, call, walletOwner)
    const err = await sendCall(c, local.id, prepared.request, prepared.gas).then(
      () => null,
      (e: unknown) => e,
    )
    expect(err, 'refused').toBeInstanceOf(BaseError)
    expect((err as BaseError).walk((e) => e instanceof ChainMismatchError), 'for the chain').toBeTruthy()

    expect(await wrongPub.getTransactionCount({ address: walletOwner }), 'nothing sent on the other network').toBe(before)
  }, 20_000)

  it('reports a transaction that lands and reverts as reverted, not as unknown', async () => {
    // An unverified caller: the desk's mint reverts in the gate. A fixed gas limit skips the estimate, so it lands.
    const hash = await wallet.writeContract({ account: sender, address: d.desk, abi: deskCallAbi, functionName: 'claimNotes', gas: 400_000n } as never)
    const outcome = await waitForOutcome(config(), local.id, hash, 10_000)
    expect(outcome.kind).toBe('reverted')
  }, 20_000)

  it('reports a transaction the wallet cancelled as cancelled, not as a success', async () => {
    await pub.request({ method: 'evm_setAutomine' as never, params: [false] as never })
    const nonce = await pub.getTransactionCount({ address: sender, blockTag: 'pending' })
    const fees = { maxFeePerGas: 2_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n }
    const hash = await wallet.writeContract({ account: sender, address: d.desk, abi: deskCallAbi, functionName: 'onboard', args: [724], gas: 200_000n, nonce, ...fees } as never)
    const waiting = waitForOutcome(config(), local.id, hash, 15_000)
    await new Promise((r) => setTimeout(r, 1_000))
    // What a wallet's cancel does: a zero-value transfer to itself at the same nonce, at a higher fee.
    await wallet.sendTransaction({ account: sender, to: sender, value: 0n, nonce, gas: 21_000n, maxFeePerGas: 4_000_000_000n, maxPriorityFeePerGas: 2_000_000_000n } as never)
    await pub.request({ method: 'evm_mine' as never })
    await pub.request({ method: 'evm_setAutomine' as never, params: [true] as never })
    expect((await waiting).kind).toBe('cancelled')
  }, 30_000)

  it('gives up after its timeout and reports the outcome as unknown', async () => {
    await pub.request({ method: 'evm_setAutomine' as never, params: [false] as never })
    const hash = await wallet.writeContract({ account: sender, address: d.desk, abi: deskCallAbi, functionName: 'onboard', args: [724], gas: 200_000n } as never)
    const outcome = await waitForOutcome(config(), local.id, hash, 2_000)
    expect(outcome.kind).toBe('unknown')
    await pub.request({ method: 'anvil_dropAllTransactions' as never })
    await pub.request({ method: 'evm_setAutomine' as never, params: [true] as never })
  }, 10_000)
})
