import { execFileSync } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { checkSource, engineSource, moduleSource, sourceCommit, type SourceAnchor } from '../src/config/source'

// Reads the file at the pinned commit, not the working tree: the links point there. CI fetches the full history.
const lines = (path: string) => execFileSync('git', ['show', `${sourceCommit}:${path}`], { encoding: 'utf8' }).split('\n')
const line = (a: SourceAnchor, n: number) => lines(a.path)[n - 1].trim()

describe('source links', () => {
  it('point each token check at the line that runs it', () => {
    const expected: Record<keyof typeof checkSource, string> = {
      pause: 'if (paused() && !_recovering) revert EnforcedPause();',
      recipientVerified: 'if (!_identityRegistry.isVerified(to)) return TransferStatus.RecipientNotVerified;',
      recipientFrozen: 'if (_frozen[to]) return TransferStatus.RecipientFrozen;',
      senderVerified: 'if (!_identityRegistry.isVerified(from)) return TransferStatus.SenderNotVerified;',
      senderFrozen: 'if (_frozen[from]) return TransferStatus.SenderFrozen;',
      unfrozen: 'if (amount > balanceOf(from) - _frozenTokens[from]) return TransferStatus.InsufficientUnfrozen;',
    }
    for (const [key, anchor] of Object.entries(checkSource)) {
      expect(line(anchor, anchor.from), key).toBe(expected[key as keyof typeof checkSource])
    }
  })

  it('span each moduleCheck and the engine loop from the signature to the closing brace', () => {
    const spans: [string, SourceAnchor, string][] = [
      ...Object.entries(moduleSource).map(([kind, a]) => [kind, a!, 'function moduleCheck('] as [string, SourceAnchor, string]),
      ['engine', engineSource, 'function canTransfer('],
    ]
    expect(spans).toHaveLength(5)
    for (const [name, a, signature] of spans) {
      expect(line(a, a.from).startsWith(signature), name).toBe(true)
      expect(line(a, a.to!), name).toBe('}')
    }
  })
})
