# blockchain-dev

Homework for the Rise In course [Solidity Fundamentals](https://www.risein.com/courses/solidity-fundamentals).

| File | Content |
|---|---|
| `Counter.sol` | Task 1: Counter contract with the additional query function `get_description()` |
| `ProposalContract.sol` | Tasks 2–4 and final task: proposal voting contract |
| `test/` | Tests for `ProposalContract.sol` on a local EVM (Ganache) |
| `requirements.md` | What has to be handed in at the end of the course |

## ProposalContract

Deployed on the Sepolia testnet: [`0x1936327040029fdAc40bdC5A2B15C635D5EcCF6f`](https://sepolia.etherscan.io/address/0x1936327040029fdAc40bdC5A2B15C635D5EcCF6f)

Differences to the course version:

- **Title:** every proposal has a `title` in addition to its `description`. `create(_title, _description, _total_vote_to_end)` takes it as a parameter.
- **Own state logic** (`calculateCurrentState`): "60% supermajority with quorum"
  1. At least half of `total_vote_to_end` votes must be cast, otherwise the proposal fails.
  2. Pass votes are abstentions: they count towards the quorum but not towards the decision.
  3. More than 60% of the approve + reject votes must be approve.
- **Fixes** so the contract works in every case:
  - `create` rejects `total_vote_to_end == 0` (the vote function would underflow otherwise).
  - `create` resets the voters, so people who voted on a terminated proposal can vote on the next one.
  - `vote` rejects choices other than 0, 1 and 2 instead of silently using up the vote.

Choices for `vote`: `0` = pass, `1` = approve, `2` = reject.

## Tests

```sh
cd test
npm install
npm test
```
