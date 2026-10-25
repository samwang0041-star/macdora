# Macdora contributor instructions

Macdora is an early preview of a Mac compatibility platform for people and agents.

## Public repository and releases

- `samwang0041-star/macdora` is the public source repository and the only active Release/update repository.
- Build lightweight installers. Download Android dependencies on demand; ship no third-party application APKs or user runtime data.
- The client reads public GitHub Releases over HTTPS without a token. Publisher credentials belong in the maintainer's local credential store or CI secrets.
- Publish only after explicit user authorization and with `MACDORA_CONFIRM_RELEASE=1` plus `--publish`. A build or local merge alone does not authorize publication.
- Public commits, documentation, fixtures and screenshots use neutral sample data. Keep private development history, personal application identities, device records and authentication material outside public Git history.

## Implementation and validation

- Reuse the existing AppKit components, semantic colors, spacing and interaction patterns. Keep visible product information brief.
- Preserve runtime ownership, input focus checks, application data and transactional image upgrades. Treat Agent support as a roadmap until an interface is implemented and tested.
- Run focused tests during implementation and the existing full Swift suite at acceptance. Check native windows and screenshots for UI changes.
- Keep upstream license and copyright notices with vendored code and patches. Update `THIRD_PARTY_NOTICES.md` when adding or changing a component.
