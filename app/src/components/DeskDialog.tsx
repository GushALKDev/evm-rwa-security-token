import { useState } from 'react'
import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { deskCallAbi } from '../lib/abi'
import { countries, countryLabel } from '../lib/countries'
import { formatDate, formatDuration, formatNotes, formatTimestamp } from '../lib/format'
import { identityWhy } from '../lib/gate'
import { labelOf, type TokenModel } from '../lib/model'
import { Dialog } from './Wallet'

export function DeskDialog({ model, onClose, onConnect }: { model: TokenModel; onClose: () => void; onConnect: () => void }) {
  const { address, chainId, status } = useConnection()
  const d = model.deployment
  const st = model.static
  const acc = model.account
  const [country, setCountry] = useState(() => (acc?.party.country && acc.party.country !== 0 ? acc.party.country : 724))
  const { run, busy } = useTx({ labelOf: (a) => labelOf(d, address, a) })
  const watch = useWatchAsset()

  const noGas = acc?.extras?.eth === 0n
  const wrongChain = status === 'connected' && chainId !== chain.id
  const why = acc ? identityWhy(acc.party, model.chainTime) : null
  const nextClaim = acc?.extras?.nextClaimAt ?? 0n
  const claimOpen = model.chainTime >= nextClaim
  const restrictedOwn = acc ? model.gate.restricted.get(acc.party.country) === true : false
  const restrictedPick = model.gate.restricted.get(country) === true
  const notes = formatNotes(st.notesPerClaim)

  return (
    <Dialog title="Test notes" onClose={onClose}>
      <p className="muted">
        The desk is a testnet stand-in for the KYC provider and the issuer. It verifies your wallet with the country you
        declare, checking nothing else, and issues {notes} notes a day. Transactions also need a little {chain.name} ETH for
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
              {restrictedPick ? (
                <p className="hint" data-tone="warn">
                  {countryLabel(country)} is restricted here. The desk will verify you, and the jurisdiction rule will
                  then stop every note sent to you, including the desk's own issue.
                </p>
              ) : null}
            </div>
          </div>

          <div className="flow-step">
            <b aria-hidden="true">2</b>
            <div className="desk-step">
              <h3>Get {notes} notes</h3>
              <p className="hint">
                {why !== 'verified'
                  ? 'The mint runs the full gate, so your wallet has to be verified first.'
                  : restrictedOwn
                    ? `Your country, ${countryLabel(acc.party.country)}, is restricted, so the jurisdiction rule stops the mint. Verify again with another country to receive notes.`
                    : !claimOpen
                      ? `The desk issues to each wallet once a day. Yours opens again on ${formatTimestamp(nextClaim)}.`
                      : `Minted through the issuer role the desk holds. Your lockup clock starts on the first notes you receive.`}
              </p>
              <div className="inline-form">
                <button
                  className="btn btn-primary"
                  disabled={!!busy || noGas || wrongChain || why !== 'verified' || restrictedOwn || !claimOpen}
                  onClick={() =>
                    run(
                      `Get ${notes} notes`,
                      `${notes} notes received`,
                      { address: d.desk, abi: deskCallAbi, functionName: 'claimNotes' },
                      { afterPrevious: true },
                    )
                  }
                >
                  Get {notes} notes
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
            </div>
          </div>

          <dl className="rows">
            <div className="row">
              <dt>Your notes</dt>
              <dd>{formatNotes(acc.party.balance)}</dd>
            </div>
          </dl>
        </div>
      )}
    </Dialog>
  )
}
