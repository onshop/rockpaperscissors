const truffleAssert = require('truffle-assertions');
const timeMachine = require('ganache-time-traveler');
const Game = artifacts.require("./RockPaperScissors.sol");

contract('rcp', async accounts => {

    const { toBN, soliditySha3 } = web3.utils;
    const { getBalance, getTransaction } = web3.eth;
    const playerOneSecretString = "secret1";
    const playerTwoSecretString = "secret2";
    const wrongSecretString = "wrongSecret";
    
    const ROCK = 0;
    const PAPER = toBN(1);
    const SCISSORS = toBN(2);

    const INIT = "0";
    const PLAYER_ONE_MOVE = "1";
    const PLAYER_TWO_MOVE = "2";
    const PLAYER_ONE_REVEAL = "3";

    const INVALID_MOVE_MSG = "Invalid move";
    const INVALID_STEP_MSG = "Invalid step";
    const HASH_MISMATCH_MSG = "Move and secret do not match";
    const GAME_NOT_EXPIRED_MSG = "Game has not expired";
    const MOVE_HASH_EMPTY_MSG = "Move hash is empty";
    const SECRET_EMPTY_MSG = "Secret is empty";
    const INVALID_PLAYER_MSG = "Invalid player";

    const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
    const ZERO_BYTES_32 = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const DAY_24_HOUR_IN_SECS = 86400;

    const getBlockTimeStamp = async(txObj) => {

        const tx = await getTransaction(txObj.tx);
        const blockData = await web3.eth.getBlock(tx.blockNumber)

        return blockData.timestamp;
    }

    const checkEventNotEmitted = async () => {
        const result = await truffleAssert.createTransactionResult(rcp, rcp.transactionHash);

        await truffleAssert.eventNotEmitted(
            result
        );
    };

    const getGasCost = async txObj => {
        const tx = await getTransaction(txObj.tx);

        return toBN(txObj.receipt.gasUsed).mul(toBN(tx.gasPrice));
    };

    const [contractOwner, playerOne, playerTwo, playerThree] = accounts;
    const playerOneSecretBytes32 = await soliditySha3(playerOneSecretString);
    const playerTwoSecretBytes32 = await soliditySha3(playerTwoSecretString);
    const wrongSecretBytes32 = await soliditySha3(wrongSecretString);

    let rcp;
    let gameKey;
    let playerTwoMoveHash;
    let snapshotId;

    beforeEach("Deploy and prepare", async function() {
        rcp = await Game.new({from: contractOwner});
        gameKey = await rcp.createPlayerOneMoveHash(playerOneSecretBytes32, ROCK, {from: playerOne});
        playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});
        const snapShot = await timeMachine.takeSnapshot();
        snapshotId = snapShot['result'];
    });

    afterEach(async() => {
        await timeMachine.revertToSnapshot(snapshotId);
    });

    it("createPlayerOneMoveHash() hashes the player's address, secret and move", async () => {
        const expectedMoveHash =  await soliditySha3(playerOne, playerOneSecretBytes32, 0);
        assert.strictEqual(expectedMoveHash, gameKey);
    });

    it("Player one creates a game", async () => {
        const txObj = await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});

        await truffleAssert.eventEmitted(txObj, 'PlayerOneMoves', (ev) => {

            return  ev.player === playerOne &&
                    ev.gameKey === gameKey &&
                    ev.stake.toString(10) === "10" &&
                    ev.amount.toString(10) === "10"
        },'PlayerOneMoves event is emitted');

        const game = await rcp.games(gameKey);

        assert.strictEqual(game.stake.toString(10), "10");
        assert.strictEqual(game.playerOne, playerOne);
        assert.strictEqual(game.step.toString(10), PLAYER_ONE_MOVE);

        const playerOneOwed = toBN(await rcp.balances(playerOne));

        assert.strictEqual(playerOneOwed.toString(10), "0");
    });

    it("Value sent that exceeds the stake, is sent to the player's balance", async () => {
        await rcp.movePlayerOne(gameKey, toBN(5), {from: playerOne, value: toBN(7)});

        const playerOneOwed = await rcp.balances(playerOne);
        assert.strictEqual(playerOneOwed.toString(10), "2");
    });

    it("createPlayerTwoMoveHash() hashes the player's address, game key, secret and move", async () => {
        const expectedMoveHash =  await soliditySha3(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
        assert.strictEqual(expectedMoveHash, playerTwoMoveHash);
    });

    it("Player two moves", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        const txObj = await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});

        const timestamp = await getBlockTimeStamp(txObj);
        const expiryDate = timestamp + DAY_24_HOUR_IN_SECS;

        await truffleAssert.eventEmitted(txObj, 'PlayerTwoMoves', (ev) => {

            return  ev.player === playerTwo &&
                    ev.amount.toString(10) === "10" &&
                    ev.gameKey === gameKey &&
                    ev.moveHash === playerTwoMoveHash &&
                    ev.expiryDate.toString(10) === expiryDate.toString(10)
        },'PlayerTwoMoves event is emitted');

        const game = await rcp.games(gameKey);

        assert.strictEqual(game.playerTwo, playerTwo);
        assert.strictEqual(game.playerTwoMoveHash, playerTwoMoveHash);
        assert.strictEqual(game.step.toString(10), PLAYER_TWO_MOVE);
    });

    it("Player one reveals", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        const txObj = await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

        const timestamp = await getBlockTimeStamp(txObj);
        const expiryDate = timestamp + DAY_24_HOUR_IN_SECS;

        await truffleAssert.eventEmitted(txObj, 'PlayerOneReveals', (ev) => {

            return  ev.player === playerOne &&
                    ev.gameKey === gameKey &&
                    ev.move.toString(10) === "0" &&
                    ev.expiryDate.toString(10) === expiryDate.toString(10)
        },'PlayerOneReveals event is emitted');

        const game = await rcp.games(gameKey);
        assert.strictEqual(game.playerOneMove.toString(10), ROCK.toString(10));
        assert.strictEqual(game.step.toString(10), PLAYER_ONE_REVEAL);
        assert.strictEqual(game.expiryDate.toString(10), expiryDate.toString(10));
    });


    it("Player two reveals and player two wins", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        const txObj = await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});

        await truffleAssert.eventEmitted(txObj, 'PlayerTwoReveals', (ev) => {

            return  ev.player === playerTwo &&
                    ev.gameKey === gameKey &&
                    ev.move.toString(10) === "1"
        },'PlayerTwoReveals event is emitted');

        await truffleAssert.eventEmitted(txObj, 'GamePayment', (ev) => {

            return  ev.player === playerTwo &&
                ev.gameKey === gameKey &&
                ev.amount.toString(10) === "19"
        },'GamePayment event is emitted');

       await truffleAssert.eventEmitted(txObj, 'GamePayment', (ev) => {

            return  ev.player === playerOne &&
                ev.gameKey === gameKey &&
                ev.amount.toString(10) === "1"
        },'GamePayment event is emitted');

        const game = await rcp.games(gameKey);
        assert.strictEqual(game.stake.toString(10), INIT);
        assert.strictEqual(game.playerOne, playerOne);
        assert.strictEqual(game.playerTwo, ZERO_ADDRESS);
        assert.strictEqual(game.playerTwoMoveHash, ZERO_BYTES_32);
        assert.strictEqual(game.playerOneMove.toString(10), "0");
        assert.strictEqual(game.expiryDate.toString(10), "0");
        assert.strictEqual(game.step.toString(10), INIT);

        const playerOneOwed = await rcp.balances(playerOne);
        const playerTwoOwed = await rcp.balances(playerTwo);

        assert.strictEqual(playerOneOwed.toString(10), "1");
        assert.strictEqual(playerTwoOwed.toString(10), "19");
    });

    it("Player two reveals and the game is a draw", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        const playerTwoSameMoveHash = await rcp.createPlayerTwoMoveHash(gameKey, playerTwoSecretBytes32, ROCK, {from: playerTwo});
        await rcp.movePlayerTwo(gameKey, playerTwoSameMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        const txObj = await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, ROCK, {from: playerTwo});

        await truffleAssert.eventEmitted(txObj, 'DrawRefund', (ev) => {

            return  ev.playerOne === playerOne &&
                    ev.playerTwo === playerTwo &&
                    ev.gameKey === gameKey &&
                    ev.playerOneRefund.toString(10) === "10" &&
                    ev.playerTwoRefund.toString(10) === "10"
        },'DrawRefund event is emitted');

        const playerOneOwed = await rcp.balances(playerOne);
        const playerTwoOwed = await rcp.balances(playerTwo);

        assert.strictEqual(playerOneOwed.toString(10), "10");
        assert.strictEqual(playerTwoOwed.toString(10), "10");
    });

    it("Player one does not reveal and player two collects forfeit", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        const txObj = await rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo});

        await truffleAssert.eventEmitted(txObj, 'ForfeitPaid', (ev) => {

            return  ev.player === playerTwo &&
                ev.gameKey === gameKey &&
                ev.amount.toString(10) === "20"
        },'ForfeitPaid event is emitted');

        const playerOneOwed = await rcp.balances(playerOne);
        const playerTwoOwed = await rcp.balances(playerTwo);

        assert.strictEqual(playerOneOwed.toString(10), "0");
        assert.strictEqual(playerTwoOwed.toString(10), "20");

    });

    it("Player two does not reveal and player one collects forfeit", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        const txObj = await rcp.playerOneCollectsForfeit(gameKey, {from: playerOne});

        await truffleAssert.eventEmitted(txObj, 'ForfeitPaid', (ev) => {

            return  ev.player === playerOne &&
                    ev.gameKey === gameKey &&
                    ev.amount.toString(10) === "20"
        },'ForfeitPaid event is emitted');

        const playerOneOwed = await rcp.balances(playerOne);
        const playerTwoOwed = await rcp.balances(playerTwo);

        assert.strictEqual(playerOneOwed.toString(10), "20");
        assert.strictEqual(playerTwoOwed.toString(10), "0");

    });

    it("Player two can stake their winnings in a subsequent game", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});

        const initPlayerTwoOwed = await rcp.balances(playerTwo);
        assert.strictEqual(initPlayerTwoOwed.toString(10), "19");

        const playerMoveHash = await rcp.createPlayerOneMoveHash(playerOneSecretBytes32, ROCK, {from: playerTwo});
        await rcp.movePlayerOne(playerMoveHash, toBN(10), {from: playerTwo});

        const playerTwoOwed = await rcp.balances(playerTwo);
        assert.strictEqual(playerTwoOwed.toString(10), "9");

    });

    it("Player ends the game early and collects their stake", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        const txObj = await rcp.playerOneEndsGame(gameKey, {from: playerOne});

        await truffleAssert.eventEmitted(txObj, 'PlayerOneEndsGame', (ev) => {

            return  ev.player === playerOne &&
                    ev.gameKey === gameKey &&
                    ev.amount.toString(10) === "10"
        },'PlayerOneEndsGame event is emitted');

        const playerOneOwed = await rcp.balances(playerOne);
        assert.strictEqual(playerOneOwed.toString(10), "10");

    });


    it("Player ends the game early, collects their stake and withdraws their balance", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.playerOneEndsGame(gameKey, {from: playerOne});

        const initPlayerOneEthBalance = toBN(await getBalance(playerOne));

        const txObj = await rcp.withdraw(toBN(5), {from: playerOne});

        await truffleAssert.eventEmitted(txObj, 'WithDraw', (ev) => {

            return  ev.player === playerOne &&
                ev.amount.toString(10) === "5"
        },'WithDraw event is emitted');

        const cost = await getGasCost(txObj);

        const playerOneEthBalance = toBN(await getBalance(playerOne));
        const playerOneOwed = toBN(await rcp.balances(playerOne));
        const expectedPlayerOneEthBalance = initPlayerOneEthBalance.add(toBN(5)).sub(cost).toString(10);

        assert.strictEqual(playerOneEthBalance.toString(10), expectedPlayerOneEthBalance);
        assert.strictEqual(playerOneOwed.toString(10), "5");

    });


    it("In Paper vs Rock, Paper wins", async () => {
        const isPaperWinner = await rcp.isWinner(PAPER, ROCK);

        assert.isTrue(isPaperWinner);
    });

    it("In Rock vs Scissors, Rock wins", async () => {
        const isRockWinner = await rcp.isWinner(ROCK, SCISSORS);

        assert.isTrue(isRockWinner);
    });

    it("In Scissors vs Paper, Scissors wins", async () => {
        const isScissorsWinner = await rcp.isWinner(SCISSORS, PAPER);

        assert.isTrue(isScissorsWinner);
    });


    it("Call reverts when player one moves with an empty hash", async () => {
        await truffleAssert.reverts(
            rcp.movePlayerOne(ZERO_BYTES_32, toBN(10), {from: playerOne, value: toBN(10)}),
            MOVE_HASH_EMPTY_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one moves with a hash already in use", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.playerOneEndsGame(gameKey, {from: playerOne});

        await truffleAssert.reverts(
            rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)}),
            INVALID_MOVE_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one moves with insufficient funds", async () => {
        await truffleAssert.reverts(
            rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(9)}),
            "Insufficient balance"
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two moves with an empty game key", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.movePlayerTwo(gameKey, ZERO_BYTES_32, {from: playerTwo, value: toBN(10)}),
            MOVE_HASH_EMPTY_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two moves a second time", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)}),
            INVALID_STEP_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two moves with insufficient funds", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(9)}),
            "Insufficient balance"
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two moves with insufficient funds", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(9)}),
            "Insufficient balance"
        );
        checkEventNotEmitted();
    });
    it("Call reverts when an invalid address calls player one reveal", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerThree}),
            INVALID_STEP_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when an invalid secret is used for the player one reveal", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.revealPlayerOne(wrongSecretBytes32, ROCK, {from: playerOne}),
            INVALID_STEP_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when an invalid move is used for the player one reveal", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await truffleAssert.reverts(
            rcp.revealPlayerOne(playerTwoSecretBytes32, SCISSORS, {from: playerOne}),
            INVALID_STEP_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when an invalid address calls player two reveal", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

        await truffleAssert.reverts(
            rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerThree}),
            HASH_MISMATCH_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when an invalid secret is used for the player one reveal", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

        await truffleAssert.reverts(
            rcp.revealPlayerTwo(gameKey, wrongSecretBytes32, PAPER, {from: playerTwo}),
            HASH_MISMATCH_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when an invalid move is used for the player one reveal", async () => {
        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

        await truffleAssert.reverts(
            rcp.revealPlayerTwo(gameKey, playerOneSecretBytes32, SCISSORS, {from: playerTwo}),
            HASH_MISMATCH_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one collects forfeit before player one reveals", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});

        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        await truffleAssert.reverts(
            rcp.playerOneCollectsForfeit(gameKey, {from: playerOne}),
            INVALID_STEP_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two tries to collect player one's forfeit", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        await truffleAssert.reverts(
            rcp.playerOneCollectsForfeit(gameKey, {from: playerTwo}),
            INVALID_PLAYER_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one collects forfeit before the game has expired", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

        await truffleAssert.reverts(
            rcp.playerOneCollectsForfeit(gameKey, {from: playerOne}),
            GAME_NOT_EXPIRED_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two collects forfeit after player one reveals", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        await truffleAssert.reverts(
            rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo}),
            INVALID_STEP_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one tries to collect player two's forfeit", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});

        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        await truffleAssert.reverts(
            rcp.playerTwoCollectsForfeit(gameKey, {from: playerOne}),
            INVALID_PLAYER_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one collects forfeit before the game has expired", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});

        await truffleAssert.reverts(
            rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo}),
            GAME_NOT_EXPIRED_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one creates a move hash with a zero bytes secret", async () => {

        await truffleAssert.reverts(
            rcp.createPlayerOneMoveHash(ZERO_BYTES_32, ROCK, {from: playerOne}),
            SECRET_EMPTY_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player one creates a move hash with an invalid move", async () => {

        await truffleAssert.reverts(
            rcp.createPlayerOneMoveHash(playerOneSecretBytes32, toBN(3), {from: playerOne}),
            INVALID_MOVE_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two creates a move hash with a zero bytes game key", async () => {

        await truffleAssert.reverts(
            rcp.createPlayerTwoMoveHash(ZERO_BYTES_32, playerOneSecretBytes32, ROCK, {from: playerOne}),
            "Game key cannot be empty"
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two creates a move hash with a zero bytes secret", async () => {

        await truffleAssert.reverts(
            rcp.createPlayerTwoMoveHash(gameKey, ZERO_BYTES_32, ROCK, {from: playerOne}),
            SECRET_EMPTY_MSG
        );
        checkEventNotEmitted();
    });

    it("Call reverts when player two creates a move hash with an invalid move", async () => {

        await truffleAssert.reverts(
            rcp.createPlayerTwoMoveHash(gameKey, playerTwoSecretBytes32, toBN(3), {from: playerOne}),
            INVALID_MOVE_MSG
        );
        checkEventNotEmitted();
    });

    it("Player one move is pausable and unpausable", async () => {

        await rcp.pause({from: contractOwner});

        await truffleAssert.reverts(
            rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)}),
            "Pausable: paused"
        );
        checkEventNotEmitted();

        await rcp.unpause({from: contractOwner});
        const txObj = await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await truffleAssert.eventEmitted(txObj, 'PlayerOneMoves');
    });

    it("Player two move is pausable and unpausable", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});

        await rcp.pause({from: contractOwner});

        await truffleAssert.reverts(
            rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)}),
            "Pausable: paused"
        );
        checkEventNotEmitted();

        await rcp.unpause({from: contractOwner});
        const txObj = await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await truffleAssert.eventEmitted(txObj, 'PlayerTwoMoves');
    });

    it("Player one reveal is pausable and unpausable", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});

        await rcp.pause({from: contractOwner});

        await truffleAssert.reverts(
            rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne}),
            "Pausable: paused"
        );
        checkEventNotEmitted();

        await rcp.unpause({from: contractOwner});
        const txObj = await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await truffleAssert.eventEmitted(txObj, 'PlayerOneReveals');
    });

    it("Player two reveal is pausable and unpausable", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

        await rcp.pause({from: contractOwner});

        await truffleAssert.reverts(
            rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo}),
            "Pausable: paused"
        );
        checkEventNotEmitted();

        await rcp.unpause({from: contractOwner});
        const txObj = await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});
        await truffleAssert.eventEmitted(txObj, 'PlayerTwoReveals');
    });

    it("Player one collecting forfeit is pausable and unpausable", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        await rcp.pause({from: contractOwner});

        await truffleAssert.reverts(
            rcp.playerOneCollectsForfeit(gameKey, {from: playerOne}),
            "Pausable: paused"
        );
        checkEventNotEmitted();

        await rcp.unpause({from: contractOwner});
        const txObj = await rcp.playerOneCollectsForfeit(gameKey, {from: playerOne});
        await truffleAssert.eventEmitted(txObj, 'ForfeitPaid');
    });

    it("Player two collecting forfeit is pausable and unpausable", async () => {

        await rcp.movePlayerOne(gameKey, toBN(10), {from: playerOne, value: toBN(10)});
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(10)});
        await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

        await rcp.pause({from: contractOwner});

        await truffleAssert.reverts(
            rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo}),
            "Pausable: paused"
        );
        checkEventNotEmitted();

        await rcp.unpause({from: contractOwner});
        const txObj = await rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo});
        await truffleAssert.eventEmitted(txObj, 'ForfeitPaid');
    });
});
