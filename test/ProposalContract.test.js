// Tests ProposalContract.sol on a local in-memory EVM (Ganache) instead of Remix.
// Run: cd test && npm install && npm test
const { test, before } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const solc = require("solc");
const ganache = require("ganache");
const { ethers } = require("ethers");

const APPROVE = 1, REJECT = 2, PASS = 0;

let ganacheProvider, provider, signers, abi, bytecode;

before(async () => {
    const source = fs.readFileSync(path.join(__dirname, "..", "ProposalContract.sol"), "utf8");
    const input = {
        language: "Solidity",
        sources: { "ProposalContract.sol": { content: source } },
        // Ganache does not support PUSH0 (shanghai), so we compile for the previous EVM version
        settings: { evmVersion: "paris", outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
    };
    const output = JSON.parse(solc.compile(JSON.stringify(input)));
    const errors = (output.errors || []).filter((e) => e.severity === "error");
    assert.strictEqual(errors.length, 0, errors.map((e) => e.formattedMessage).join("\n"));

    const compiled = output.contracts["ProposalContract.sol"].ProposalContract;
    abi = compiled.abi;
    bytecode = compiled.evm.bytecode.object;

    ganacheProvider = ganache.provider({
        logging: { quiet: true },
        wallet: { totalAccounts: 12 },
        chain: { vmErrorsOnRPCResponse: true }, // returns the revert reason so we can check it
    });
    provider = new ethers.BrowserProvider(ganacheProvider);
    signers = await Promise.all([...Array(12).keys()].map((i) => provider.getSigner(i)));
});

async function deploy() {
    const factory = new ethers.ContractFactory(abi, bytecode, signers[0]);
    const contract = await factory.deploy();
    await contract.waitForDeployment();
    return contract;
}

// ethers loses the revert reason from Ganache, so we ask Ganache directly with eth_call
// and check that the call reverts with the expected message
async function assertRevert(contract, signer, fn, args, reason) {
    const data = contract.interface.encodeFunctionData(fn, args);
    const call = { from: await signer.getAddress(), to: await contract.getAddress(), data };
    await assert.rejects(ganacheProvider.request({ method: "eth_call", params: [call, "latest"] }), reason);
}

// Lets the voters signers[1..] vote with the given choices, one vote each
async function voteAll(contract, choices) {
    for (let i = 0; i < choices.length; i++) {
        await (await contract.connect(signers[i + 1]).vote(choices[i])).wait();
    }
}

test("create stores title and description", async () => {
    const contract = await deploy();
    await (await contract.create("Title", "Long description", 10)).wait();

    const p = await contract.getCurrentProposal();
    assert.strictEqual(p.title, "Title");
    assert.strictEqual(p.description, "Long description");
    assert.strictEqual(p.total_vote_to_end, 10n);
    assert.strictEqual(p.is_active, true);
    assert.strictEqual(p.current_state, false);

    const same = await contract.getProposal(1);
    assert.strictEqual(same.title, "Title");
});

test("only the owner can create, terminate and set the owner", async () => {
    const contract = await deploy();
    const other = contract.connect(signers[1]);
    await assert.rejects(other.create("T", "D", 5));
    await (await contract.create("T", "D", 5)).wait();
    await assert.rejects(other.terminateProposal());
    await assert.rejects(other.setOwner(await signers[1].getAddress()));
});

test("create rejects total_vote_to_end of 0", async () => {
    const contract = await deploy();
    await assertRevert(contract, signers[0], "create", ["T", "D", 0], /greater than 0/);
});

test("owner cannot vote and nobody can vote twice", async () => {
    const contract = await deploy();
    await (await contract.create("T", "D", 5)).wait();
    await assertRevert(contract, signers[0], "vote", [APPROVE], /already voted/);

    await voteAll(contract, [APPROVE]);
    assert.strictEqual(await contract.isVoted(await signers[1].getAddress()), true);
    await assertRevert(contract, signers[1], "vote", [REJECT], /already voted/);
});

test("invalid choice is rejected and does not use up the vote", async () => {
    const contract = await deploy();
    await (await contract.create("T", "D", 5)).wait();
    await assertRevert(contract, signers[1], "vote", [3], /Choice must be/);
    assert.strictEqual(await contract.isVoted(await signers[1].getAddress()), false);
    await voteAll(contract, [APPROVE]);
});

test("votes are counted", async () => {
    const contract = await deploy();
    await (await contract.create("T", "D", 10)).wait();
    await voteAll(contract, [APPROVE, APPROVE, REJECT, PASS]);
    const p = await contract.getCurrentProposal();
    assert.deepStrictEqual([p.approve, p.reject, p.pass], [2n, 1n, 1n]);
});

test("state: fails while quorum (half of total_vote_to_end) is not reached", async () => {
    const contract = await deploy();
    await (await contract.create("T", "D", 10)).wait();
    await voteAll(contract, [APPROVE, APPROVE, APPROVE, APPROVE]); // 4 of 10
    assert.strictEqual((await contract.getCurrentProposal()).current_state, false);
    await (await contract.connect(signers[5]).vote(APPROVE)).wait(); // 5 of 10 -> quorum
    assert.strictEqual((await contract.getCurrentProposal()).current_state, true);
});

test("state: needs more than 60% approve among approve + reject", async () => {
    const cases = [
        { votes: [APPROVE, APPROVE, APPROVE, APPROVE, REJECT], expected: true },  // 80%
        { votes: [APPROVE, APPROVE, APPROVE, REJECT, REJECT], expected: false },  // exactly 60%
        { votes: [APPROVE, APPROVE, APPROVE, REJECT, PASS, PASS], expected: true }, // 75%, pass ignored
        { votes: [PASS, PASS, PASS, PASS, PASS], expected: false },                 // only abstentions
    ];
    for (const { votes, expected } of cases) {
        const contract = await deploy();
        await (await contract.create("T", "D", 10)).wait();
        await voteAll(contract, votes);
        assert.strictEqual((await contract.getCurrentProposal()).current_state, expected, JSON.stringify(votes));
    }
});

test("proposal ends when total_vote_to_end is reached", async () => {
    const contract = await deploy();
    await (await contract.create("T", "D", 3)).wait();
    await voteAll(contract, [APPROVE, APPROVE, REJECT]);
    const p = await contract.getCurrentProposal();
    assert.strictEqual(p.is_active, false);
    assert.strictEqual(p.current_state, true); // 2 of 3 = 66% > 60%
    await assert.rejects(contract.connect(signers[4]).vote(APPROVE));
});

test("terminateProposal stops voting and voters can vote on the next proposal", async () => {
    const contract = await deploy();
    await (await contract.create("First", "D", 10)).wait();
    await voteAll(contract, [APPROVE]);
    await (await contract.terminateProposal()).wait();
    assert.strictEqual((await contract.getCurrentProposal()).is_active, false);
    await assert.rejects(contract.connect(signers[2]).vote(APPROVE));

    await (await contract.create("Second", "D", 10)).wait();
    await voteAll(contract, [APPROVE]); // signers[1] voted on "First" and can vote again
    assert.strictEqual((await contract.getCurrentProposal()).title, "Second");
    assert.strictEqual((await contract.getProposal(1)).title, "First");
});

test("setOwner hands over the owner rights", async () => {
    const contract = await deploy();
    await (await contract.setOwner(await signers[1].getAddress())).wait();
    await assert.rejects(contract.create("T", "D", 5));
    await (await contract.connect(signers[1]).create("T", "D", 5)).wait();
});
