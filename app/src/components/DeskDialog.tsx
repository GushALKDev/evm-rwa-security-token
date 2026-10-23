import { useState } from 'react'
import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { deskCallAbi } from '../lib/abi'
import { countries, countryLabel } from '../lib/countries'
import { formatDate, formatDuration, formatTokens, formatTimestamp, solidityAmount } from '../lib/format'
import { evaluateGate, identityWhy } from '../lib/gate'
import { labelOf, type TokenModel } from '../lib/model'
import { Calls } from './Calls'
import { checkText } from './gateText'
import { Dialog } from './Wallet'

export function DeskDialog({ model, onClose, onConnect }: { model: TokenModel; onClose: () => void; onConnect: () => void }) {
  const { address, chainId, status } = useConnection()
  const d = model.deployment
  const st = model.static
  const acc = model.account
  const [country, setCountry] = useState(() => (acc?.party.country && acc.party.country !== 0 ? acc.party.country : 724))
  // The desk's mint runs the token's full gate: the same mirror the transfer gate draws decides whether it would pass.
  const mint = acc ? evaluateGate(model.gate, null, acc.party, st.tokensPerClaim, model.chainTime) : null
  const stop = mint && mint.stoppedAt !== null ? checkText(mint.checks[mint.stoppedAt], model, null, acc!.party, st.tokensPerClaim) : null
  const { run, busy } = useTx({
    labelOf: (a) => labelOf(d, address, a),
    rejectingRule: stop ? `${stop.title}. ${stop.detail}` : undefined,
  })
  const watch = useWatchAsset()

  const noGas = acc?.extras?.eth === 0n
  const wrongChain = status === 'connected' && chainId !== chain.id
  const why = acc ? identityWhy(acc.party, model.chainTime) : null
  const nextClaim = acc?.extras?.nextClaimAt ?? 0n
  const claimOpen = model.chainTime >= nextClaim
  const restrictedOwn = acc ? model.gate.restricted.get(acc.party.country) === true : false
  const restrictedPick = model.gate.restricted.get(country) === true
  const tokens = formatTokens(st.tokensPerClaim)

  return (
    <Dialog title="Test tokens" onClose={onClose}>
      <p className="muted">
        The desk is a testnet stand-in for the KYC provider and the issuer. It verifies your wallet with the country you
        declare, checking nothing else, and issues {tokens} tokens a day. Transactions also need a little {chain.name} ETH for
        gas.
      </p>

      {!address ? (
        <button className="btn btn-primary btn-block" style={{ marginTop: 18 }} onClick={onConnect}>
          Connect wallet
        </button>
      ) : !acc ? (
        <p className="muted" style={{ marginTop: 18 }}>
          Reading your wallet…
        </p>
      ) : (
        <div className="desk-steps">
          {wrongChain ? (
            <div className="callout" data-tone="warn">
              Your wallet is on another network. Switch to {chain.name} from the button at the top first.
            </div>
          ) : null}
          {noGas ? (
            <div className="callout" data-tone="warn">
              Your wallet has no {chain.name} ETH. Get some from a{' '}
              <a href={links.ethFaucet} target="_blank" rel="noreferrer">
                {chain.name} faucet
              </a>{' '}
              first, then come back.
            </div>
          ) : null}

          <div className="flow-step">
            <b aria-hidden="true">1</b>
            <div className="desk-step">
              <h3>Verify your wallet</h3>
              <p className="hint">
                {why === 'verified'
                  ? `Verified in ${countryLabel(acc.party.country)} until ${formatDate(acc.party.kycExpiry)}. Verify again to change the country or renew the ${formatDuration(Number(st.kycValidity))}.`
                  : why === 'lapsed'
                    ? `Your KYC lapsed on ${formatTimestamp(acc.party.kycExpiry)}. Verify again to renew it.`
                    : `Writes your wallet to the identity registry for ${formatDuration(Number(st.kycValidity))}, through the agent role the desk holds.`}
              </p>
              <div className="inline-form">
                <select
                  className="select"
                  aria-label="Country of residence"
                  value={country}
                  onChange={(e) => setCountry(Number(e.target.value))}
                >
                  {countries.map((c) => (
                    <option key={c.code} value={c.code}>
                      {c.name}
                      {model.gate.restricted.get(c.code) ? ' (restricted)' : ''}
                    </option>
                  ))}
                </select>
                <button
                  className={why === 'verified' ? 'btn' : 'btn btn-primary'}
                  disabled={!!busy || noGas || wrongChain}
                  onClick={() =>
                    run('Verify wallet', 'Wallet verified', {
                      address: d.desk,
                      abi: deskCallAbi,
                      functionName: 'onboard',
                      args: [country],
                    })
                  }
                >
                  {why === 'verified' ? 'Verify again' : 'Verify'}
                </button>
              </div>
              <Calls
                call={`TestnetDesk.onboard(${country})`}
                then={[`IdentityRegistry.registerIdentity(msg.sender, ${country}, false, block.timestamp + ${formatDuration(Number(st.kycValidity))})`]}
              />
              {restrictedPick ? (
                <p className="hint" data-tone="warn">
                  {countryLabel(country)} is restricted here. The desk will verify you, and the jurisdiction rule will
                  then stop every token sent to you, including the desk's own issue.
                </p>
              ) : null}
            </div>
          </div>

          <div className="flow-step">
            <b aria-hidden="true">2</b>
            <div className="desk-step">
              <h3>Get {tokens} tokens</h3>
              <p className="hint">
                {why !== 'verified'
                  ? 'The mint runs the full gate, so your wallet has to be verified first.'
                  : restrictedOwn
                    ? `Your country, ${countryLabel(acc.party.country)}, is restricted, so the jurisdiction rule stops the mint. Verify again with another country to receive tokens.`
                    : stop
                      ? `The mint would stop at check ${mint!.stoppedAt! + 1}, ${stop.title.toLowerCase()}: ${stop.detail}`
                      : !claimOpen
                        ? `The desk issues to each wallet once a day. Yours opens again on ${formatTimestamp(nextClaim)}.`
                        : `Minted through the issuer role the desk holds. Your lockup clock starts on the first tokens you receive.`}
              </p>
              <div className="inline-form">
                <button
                  className="btn btn-primary"
                  disabled={!!busy || noGas || wrongChain || why !== 'verified' || restrictedOwn || !!stop || !claimOpen}
                  onClick={() =>
                    run(
                      `Get ${tokens} tokens`,
                      `${tokens} tokens received`,
                      { address: d.desk, abi: deskCallAbi, functionName: 'claimTokens' },
                      { afterPrevious: true },
                    )
                  }
                >
                  Get {tokens} tokens
                </button>
                <button
                  className="btn btn-quiet"
                  onClick={() =>
                    watch.mutate({ type: 'ERC20', options: { address: d.token, symbol: st.tokenSymbol, decimals: 18 } })
                  }
                >
                  Add {st.tokenSymbol} to wallet
                </button>
              </div>
              <Calls call="TestnetDesk.claimTokens()" then={[`SecurityToken.mint(msg.sender, ${solidityAmount(st.tokensPerClaim, 18)})`]} />
            </div>
          </div>

          <dl className="rows">
            <div className="row">
              <dt>Your tokens</dt>
              <dd>{formatTokens(acc.party.balance)}</dd>
            </div>
          </dl>
        </div>
      )}
    </Dialog>
  )
}
