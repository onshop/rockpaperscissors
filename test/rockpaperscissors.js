const truffleAssert = require('truffle-assertions');
const Game = artifacts.require("./RockPaperScissors.sol");

contract('rcp', async accounts => {

    const { toBN, soliditySha3, asciiToHex } = web3.utils;
    const { getBalance } = web3.eth;
    const playerOneSecretString = "secret1";
    const playerTwoSecretString = "secret2";
    const wrongSecretString = "wrongSecret";
    
    const rock = 1;
    const paper = 2;
    const scissors = 3;

    const noStakeToWithdrawMsg = "No stake to withdraw";
    const badMatchMsg = "Move and secret do not match";
    const alreadyMovedMsg = "Already moved";
    const invalidPlayerMsg = "Invalid player";
    const gameNotFoundMsg = "Game not found";
    const gameInProgressMsg = "Game in progress";

    const emptySecretMsg = "Secret cannot be empty";
    const emptyHashErrorMsg = "Hash cannot be empty";
    const noFundsAvailableMsg = "No funds available";

    const zeroAddress = "0x0000000000000000000000000000000000000000";
    const zeroBytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

    const checkEventNotEmitted = async () => {
        const result = await truffleAssert.createTransactionResult(remittance, remittance.transactionHash);

        await truffleAssert.eventNotEmitted(
            result
        );
    };

    const getGasCost = async txObj => {
        const tx = await web3.eth.getTransaction(txObj.tx);

        return toBN(txObj.receipt.gasUsed).mul(toBN(tx.gasPrice));
    };

    const [contractOwner, playerOne, playerTwo] = accounts;
    const playerOneSecretBytes32 = await soliditySha3(playerOneSecretString);
    const playerTwoSecretBytes32 = await soliditySha3(playerTwoSecretString);

    const emptySha3Hash = await soliditySha3("");
    const wrongSecretBytes32 = await soliditySha3(wrongSecretString);

    let rcp;
    let gameToken;
    let playerOneMoveHash;
    let playerTwoMoveHash;

    beforeEach("Deploy and prepare", async function() {
        rcp = await Game.new({from: contractOwner});
        gameToken = await rcp.createGameToken(playerOne, playerTwo, {from: contractOwner})
        playerOneMoveHash = await rcp.hashPlayerMove(gameToken, playerOne, playerOneSecretBytes32, rock);
        playerTwoMoveHash = await rcp.hashPlayerMove(gameToken, playerTwo, playerTwoSecretBytes32, scissors);
    });

    it("Initiator creates a gameToken", async () => {
        expectedGameToken = await soliditySha3(playerOne, playerTwo, rcp.address);

        assert.strictEqual(gameToken, expectedGameToken);
    });

    it("Player creates a move hash", async () => {
        expectedMoveHash = await soliditySha3(gameToken, playerOne, playerOneSecretBytes32, rock, rcp.address);

        assert.strictEqual(playerOneMoveHash, expectedMoveHash);
    });

    it("Player makes a deposit", async () => {
        const txObj = await rcp.deposit({from: playerOne, value: toBN(5)});

        await truffleAssert.eventEmitted(txObj, 'Deposit', (ev) => {

            return  ev.player === playerOne &&
                    ev.amount.toString(10) === "5"
        },'Deposit event is emitted');

        const balance = await rcp.balances(playerOne);
        assert.strictEqual(balance.toString(10), "5");
    });

    it("initiator creates a game", async () => {

        const txObj = await rcp.initialise(gameToken, playerOne, playerTwo, toBN(5), {from: contractOwner});

        await truffleAssert.eventEmitted(txObj, 'GameInitialised', (ev) => {

            return  ev.initiator === contractOwner &&
                    ev.token === gameToken &&
                    ev.playerOne === playerOne &&
                    ev.playerTwo === playerTwo &&
                    ev.stake.toString(10) === "5"
        },'GameInitialised event is emitted');

        const game = await rcp.games(gameToken);

        assert.strictEqual(game.playerOne, playerOne);
        assert.strictEqual(game.playerTwo, playerTwo);
        assert.strictEqual(game.stake.toString(10), "5");
    });


    it("Both players select different options", async () => {
        await rcp.deposit({from: playerOne, value: toBN(5)});
        await rcp.deposit({from: playerTwo, value: toBN(5)});
        await rcp.initialise(gameToken, playerOne, playerTwo, toBN(5), {from: contractOwner});

        const playerOneTxObj = await rcp.play(gameToken, playerOneMoveHash, {from: playerOne});

        await truffleAssert.eventEmitted(playerOneTxObj, 'PlayerMove', (ev) => {

            return  ev.player === playerOne &&
                    ev.token === gameToken
        },'PlayerMove event is emitted');

        const game = await rcp.games(gameToken);
        assert.strictEqual(game.playerOneMoveHash, playerOneMoveHash);
        const balance = await rcp.balances(playerOne);
        assert.strictEqual(balance.toString(10), "0");

        const playerTwoTxObj = await rcp.play(gameToken, playerTwoMoveHash, {from: playerTwo});

        await truffleAssert.eventEmitted(playerTwoTxObj, 'AllPlayersMoved', (ev) => {

            return ev.token === gameToken
        },'AllPlayersMoved event is emitted');
    });

    it("Both players reveals move", async () => {
        await rcp.deposit({from: playerOne, value: toBN(5)});
        await rcp.deposit({from: playerTwo, value: toBN(5)});

        await rcp.initialise(gameToken, playerOne, playerTwo, toBN(5), {from: contractOwner});

        await rcp.play(gameToken, playerOneMoveHash, {from: playerOne});
        await rcp.play(gameToken, playerTwoMoveHash, {from: playerTwo});

        await rcp.revealPlayerMove(gameToken, playerOneSecretBytes32, rock, {from: playerOne});
        const txObj = await rcp.revealPlayerMove(gameToken, playerTwoSecretBytes32, scissors, {from: playerTwo});

        await truffleAssert.eventEmitted(txObj, 'AllMovesRevealed', (ev) => {

            return  ev.token === gameToken
        },'AllMovesRevealed event is emitted');

        const game = await rcp.games(gameToken);

        assert.strictEqual(game.playerOneMove.toString(10), "1");
        assert.strictEqual(game.playerTwoMove.toString(10), "3");

    });

    it("Game is played and the winner rewarded", async () => {
        await rcp.deposit({from: playerOne, value: toBN(5)});
        await rcp.deposit({from: playerTwo, value: toBN(5)});

        await rcp.initialise(gameToken, playerOne, playerTwo, 5, {from: contractOwner});

        await rcp.play(gameToken, playerOneMoveHash, {from: playerOne});
        await rcp.play(gameToken, playerTwoMoveHash, {from: playerTwo});

        await rcp.revealPlayerMove(gameToken, playerOneSecretBytes32, rock, {from: playerOne});
        await rcp.revealPlayerMove(gameToken, playerTwoSecretBytes32, scissors, {from: playerTwo});

        const txObj = await rcp.determineWinner(gameToken, {from: contractOwner});

        await truffleAssert.eventEmitted(txObj, 'WinnerRewarded', (ev) => {

            return  ev.token === gameToken &&
                    ev.winner === playerOne &&
                    ev.winnings.toString(10) === "10"
        },'WinnerRewarded event is emitted');

        const game = await rcp.games(gameToken);

        assert.strictEqual(game.stake.toString(10), "0");
        assert.strictEqual(game.playerOneMove.toString(10), "0");
        assert.strictEqual(game.playerTwoMove.toString(10), "0");
        assert.strictEqual(game.playerOneMoveHash, zeroBytes32);
        assert.strictEqual(game.playerTwoMoveHash, zeroBytes32);

        const playerOneBalance = await rcp.balances(playerOne);
        const playerTwoBalance = await rcp.balances(playerTwo);

        assert.strictEqual(playerOneBalance.toString(10), "10");
        assert.strictEqual(playerTwoBalance.toString(10), "0");
    });

    it("Player one withdraws from the balance", async () => {
        await rcp.deposit({from: playerOne, value: toBN(5)});

        // Take a snapshot of the second recipient's ETH balance
        const initPlayerEthBalance = toBN(await web3.eth.getBalance(playerOne));

        const txObj = await rcp.withdraw(toBN(3), {from: playerOne});
        const cost = await getGasCost(txObj);

        await truffleAssert.eventEmitted(txObj, 'WithDraw', (ev) => {

            return  ev.withdrawer === playerOne &&
                    ev.amount.toString(10) === "3"
        },'WithDraw event is emitted');

        const playerOneBalance = await rcp.balances(playerOne);
        assert.strictEqual(playerOneBalance.toString(10), "2");

        const playerEthBalance = toBN(await web3.eth.getBalance(playerOne));
        const expectedPlayerEthBalance = initPlayerEthBalance.sub(cost).add(toBN(3)).toString(10);

        assert.strictEqual(playerEthBalance.toString(10), expectedPlayerEthBalance);

    });

    it("Player one withdraws from the game", async () => {
        await rcp.deposit({from: playerOne, value: toBN(5)});

        await rcp.initialise(gameToken, playerOne, playerTwo, toBN(5), {from: contractOwner});

        await rcp.play(gameToken, playerOneMoveHash, {from: playerOne});

        const txObj = await rcp.withDrawFromGame(gameToken, {from: playerOne});

        await truffleAssert.eventEmitted(txObj, 'PlayerWithdraws', (ev) => {

            return  ev.player === playerOne &&
                    ev.token === gameToken &&
                    ev.refund.toString(10) === "5"
        },'PlayerWithdraws event is emitted');

        const playerOneBalance = await rcp.balances(playerOne);

        assert.strictEqual(playerOneBalance.toString(10), "5");
    });
});
