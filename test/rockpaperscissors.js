const truffleAssert = require('truffle-assertions');
const timeMachine = require('ganache-time-traveler');
const Game = artifacts.require("./RockPaperScissors.sol");

contract('rcp', async accounts => {

    const { toBN, soliditySha3 } = web3.utils;
    const { getBalance, getTransaction } = web3.eth;
    const playerOneSecretString = "secret1";
    const playerTwoSecretString = "secret2";
    const wrongSecretString = "wrongSecret";
    
    const ROCK = 1;
    const PAPER = 2;
    const SCISSORS = 3;

    const DRAW = "0";
    const LEFTWIN = "1";
    const RIGHTWIN = "2";
    const INCORRECT = "3";

    const UNSTARTED = "0";
    const PLAYER_ONE_MOVE = "1";
    const PLAYER_TWO_MOVE = "2";
    const PLAYER_ONE_REVEAL = "3";

    const INVALID_MOVE_MSG = "Invalid move";
    const INVALID_STEP_MSG = "Invalid step";
    const HASH_MISMATCH_MSG = "Move and secret do not match";
    const GAME_NOT_EXPIRED_MSG = "Game has not expired";
    const SECRET_EMPTY_MSG = "Secret is empty";
    const INVALID_PLAYER_MSG = "Invalid player";

    const ZERO_ADDRESS = "0x".padEnd(42, "0");
    const ZERO_BYTES_32 = "0x".padEnd(66, "0");
    const DAY_24_HOUR_IN_SECS = 86400;
    const TIMEOUT = 14000000

    const getBlockTimeStamp = async(txObj) => {
        const blockData = await web3.eth.getBlock(txObj.receipt.blockNumber);

        return blockData.timestamp;
    }

    const getGasCost = async txObj => {
        const tx = await getTransaction(txObj.tx);

        return toBN(txObj.receipt.gasUsed).mul(toBN(tx.gasPrice));
    };

    const [contractOwner, playerOne, playerTwo, playerThree] = accounts;
    const playerOneSecretBytes32 = await soliditySha3(playerOneSecretString);
    const playerTwoSecretBytes32 = await soliditySha3(playerTwoSecretString);
    const wrongSecretBytes32 = await soliditySha3(wrongSecretString);

    let rcp, snapshotId;

    beforeEach("Deploy and prepare", async function() {
        rcp = await Game.new({from: contractOwner});
    });

    describe("Player moves", async () => {

        it("Player one hashes their address, secret and move", async () => {
            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            const expectedMoveHash =  await soliditySha3(playerOne, playerOneSecretBytes32, {type: 'uint8', value: ROCK});
            assert.strictEqual(expectedMoveHash, gameKey);
        });

        it("Player one creates a game", async () => {
            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            const txObj = await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});

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

            const playerOneOwed = await rcp.balances(playerOne);

            assert.strictEqual(playerOneOwed.toString(10), "0");
        });

        it("Value sent that exceeds the stake, is sent to the player's balance", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);

            const initPlayerOneOwed = await rcp.balances(playerOne);
            assert.strictEqual(initPlayerOneOwed.toString(10), "0");

            // 7 - 5 = 2 is added to the balance
            await rcp.movePlayerOne(gameKey, "5", {from: playerOne, value: 7});

            const playerOneOwed1 = await rcp.balances(playerOne);
            assert.strictEqual(playerOneOwed1.toString(10), "2");

            // 10 - 5 = 5 is added to the balance
            const gameKey2 = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey2, "5", {from: playerOne, value: 10});

            // Total balance is now 5 + 2
            const playerOneOwed2 = await rcp.balances(playerOne);
            assert.strictEqual(playerOneOwed2.toString(10), "7");

        });

        it("Player two hashes their address, game key, secret and move", async () => {
            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            const expectedMoveHash =  await soliditySha3(playerTwo, gameKey, playerTwoSecretBytes32, { type: "uint8", value: SCISSORS });
            assert.strictEqual(expectedMoveHash, playerTwoMoveHash);
        });

        it("Player two moves", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            const txObj = await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

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
    });

    describe("Player reveals", async () => {

        it("Player one reveals", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            const txObj = await rcp.revealPlayerOne(playerOneSecretBytes32, PAPER, {from: playerOne});

            const timestamp = await getBlockTimeStamp(txObj);
            const expiryDate = timestamp + DAY_24_HOUR_IN_SECS;

            await truffleAssert.eventEmitted(txObj, 'PlayerOneReveals', (ev) => {

                return  ev.player === playerOne &&
                        ev.gameKey === gameKey &&
                        ev.move.toString(10) === "2" &&
                        ev.expiryDate.toString(10) === expiryDate.toString(10)
            },'PlayerOneReveals event is emitted');

            const game = await rcp.games(gameKey);
            assert.strictEqual(game.playerOneMove.toString(10), PAPER.toString(10));
            assert.strictEqual(game.step.toString(10), PLAYER_ONE_REVEAL);
            assert.strictEqual(game.expiryDate.toString(10), expiryDate.toString(10));
        });


        it("Player two reveals and player two wins", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
            const txObj = await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});

            await truffleAssert.eventNotEmitted(txObj, 'DrawRefund');

            await truffleAssert.eventEmitted(txObj, 'PlayerTwoReveals', (ev) => {

                return  ev.player === playerTwo &&
                        ev.gameKey === gameKey &&
                        ev.move.toString(10) === "2"
            },'PlayerTwoReveals event is emitted');

            await truffleAssert.eventEmitted(txObj, 'GamePayment', (ev) => {

                return  ev.player === playerTwo &&
                        ev.gameKey === gameKey &&
                        ev.amount.toString(10) === "20"
            },'GamePayment event is emitted');

            const game = await rcp.games(gameKey);
            assert.strictEqual(game.stake.toString(10), UNSTARTED);
            assert.strictEqual(game.playerOne, playerOne);
            assert.strictEqual(game.playerTwo, ZERO_ADDRESS);
            assert.strictEqual(game.playerTwoMoveHash, ZERO_BYTES_32);
            assert.strictEqual(game.playerOneMove.toString(10), "0");
            assert.strictEqual(game.expiryDate.toString(10), "0");
            assert.strictEqual(game.step.toString(10), "0");

            const playerOneOwed = await rcp.balances(playerOne);
            const playerTwoOwed = await rcp.balances(playerTwo);

            assert.strictEqual(playerOneOwed.toString(10), "0");
            assert.strictEqual(playerTwoOwed.toString(10), "20");

        }).timeout(TIMEOUT);

        it("Player two reveals and the game is a draw", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoSameMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoSameMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
            const txObj = await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, ROCK, {from: playerTwo});

            await truffleAssert.eventEmitted(txObj, 'DrawRefund', (ev) => {

                return  ev.playerOne === playerOne &&
                        ev.playerTwo === playerTwo &&
                        ev.gameKey === gameKey &&
                        ev.playerOneRefund.toString(10) === "10" &&
                        ev.playerTwoRefund.toString(10) === "10"
            },'DrawRefund event is emitted');

            await truffleAssert.eventNotEmitted(txObj, 'GamePayment');

            const playerOneOwed = await rcp.balances(playerOne);
            const playerTwoOwed = await rcp.balances(playerTwo);

            assert.strictEqual(playerOneOwed.toString(10), "10");
            assert.strictEqual(playerTwoOwed.toString(10), "10");

        }).timeout(TIMEOUT);
    });

    describe("Player collects forfeit", async () => {

        beforeEach("Deploy and prepare", async function() {
            const snapShot = await timeMachine.takeSnapshot();
            snapshotId = snapShot['result'];
        });

        afterEach(async() => {
            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("Player one does not reveal and player two collects forfeit", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
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

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, SCISSORS, {from: playerOne});
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

        }).timeout(TIMEOUT);
    });

    it("Player two can stake their winnings in a subsequent game", async () => {

        const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
        await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
        const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
        await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
        await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
        await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});

        const initPlayerTwoOwed = await rcp.balances(playerTwo);
        assert.strictEqual(initPlayerTwoOwed.toString(10), "20");

        const playerMoveHash = await rcp.createPlayerOneMoveHash(playerTwo, playerOneSecretBytes32, ROCK);
        await rcp.movePlayerOne(playerMoveHash, "5", {from: playerTwo});

        const playerTwoOwed = await rcp.balances(playerTwo);
        assert.strictEqual(playerTwoOwed.toString(10), "15");

    }).timeout(TIMEOUT);

    it("Player ends the game early and collects their stake", async () => {

        const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
        await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
        const txObj = await rcp.playerOneEndsGame(gameKey, {from: playerOne});

        await truffleAssert.eventEmitted(txObj, 'PlayerOneEndsGame', (ev) => {

            return  ev.player === playerOne &&
                    ev.gameKey === gameKey &&
                    ev.amount.toString(10) === "10"
        },'PlayerOneEndsGame event is emitted');

        const playerOneOwed = await rcp.balances(playerOne);
        assert.strictEqual(playerOneOwed.toString(10), "10");

    });

    it("Player can withdraw their balance", async () => {

        const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
        await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
        await rcp.playerOneEndsGame(gameKey, {from: playerOne});

        const initPlayerOneEthBalance = toBN(await getBalance(playerOne));
        const txObj = await rcp.withdraw("5", {from: playerOne});

        await truffleAssert.eventEmitted(txObj, 'WithDraw', (ev) => {

            return  ev.player === playerOne &&
                ev.amount.toString(10) === "5"
        },'WithDraw event is emitted');

        const cost = await getGasCost(txObj);
        const playerOneEthBalance = await getBalance(playerOne);
        const playerOneOwed = await rcp.balances(playerOne);
        const expectedPlayerOneEthBalance = initPlayerOneEthBalance.add(toBN(5)).sub(cost).toString(10);

        assert.strictEqual(playerOneEthBalance.toString(10), expectedPlayerOneEthBalance);
        assert.strictEqual(playerOneOwed.toString(10), "5");

    });

    describe('Game outcome calculated', async function(){

        it("Winner correctly calculated", async () => {
            const paperWinner1 = await rcp.resolveGame(PAPER, ROCK);
            assert.strictEqual(paperWinner1.toString(10), LEFTWIN);

            const rockWinner1 = await rcp.resolveGame(ROCK, SCISSORS);
            assert.strictEqual(rockWinner1.toString(10), LEFTWIN);

            const scissorsWinner1 = await rcp.resolveGame(SCISSORS, PAPER);
            assert.strictEqual(scissorsWinner1.toString(10), LEFTWIN);

            const paperWinner2 = await rcp.resolveGame(ROCK, PAPER);
            assert.strictEqual(paperWinner2.toString(10), RIGHTWIN);

            const rockWinner2 = await rcp.resolveGame(SCISSORS, ROCK);
            assert.strictEqual(rockWinner2.toString(10), RIGHTWIN);

            const scissorsWinner2 = await rcp.resolveGame(PAPER, SCISSORS);
            assert.strictEqual(scissorsWinner2.toString(10), RIGHTWIN);

            const drawWinner = await rcp.resolveGame(SCISSORS, SCISSORS);
            assert.strictEqual(drawWinner.toString(10), DRAW);
        });

        it("Game outcome calculated and move values validated", async () => {
            const errorResultLeft1 = await rcp.resolveGame(2, 0);
            assert.strictEqual(errorResultLeft1.toString(10), INCORRECT);

            const errorResultLeft2 = await rcp.resolveGame(0, 2);
            assert.strictEqual(errorResultLeft2.toString(10), INCORRECT);
        });
    });

    describe('Player one move validation', async function() {

        it("Call reverts when player one moves with an empty hash", async () => {
            await truffleAssert.reverts(
                rcp.movePlayerOne(ZERO_BYTES_32, "10", {from: playerOne, value: 10}),
                "Game key hash is empty"
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player one moves with a game key already in use", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            await rcp.playerOneEndsGame(gameKey, {from: playerOne});

            await truffleAssert.reverts(
                rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10}),
                INVALID_MOVE_MSG
            );

        }).timeout(TIMEOUT);
        it("Call reverts when player one moves with insufficient funds", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);

            await truffleAssert.reverts(
                rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: toBN(9)}),
                "SafeMath: subtraction overflow"
            );

        }).timeout(TIMEOUT);
    });

    describe('Player two move validation', async function() {

        it("Call reverts when player two moves with an empty game key", async () => {
            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            await truffleAssert.reverts(
                rcp.movePlayerTwo(gameKey, ZERO_BYTES_32, {from: playerTwo, value: 10}),
                "Move hash is empty"
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player two moves a second time", async () => {
            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await truffleAssert.reverts(
                rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10}),
                INVALID_STEP_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player two moves with insufficient funds", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);

            await truffleAssert.reverts(
                rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: toBN(9)}),
                "SafeMath: subtraction overflow"
            );

        }).timeout(TIMEOUT);

    });
    describe('Player one reveal validation', async function() {

        it("Call reverts when an invalid address calls player one reveal", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await truffleAssert.reverts(
                rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerThree}),
                INVALID_STEP_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when an invalid secret is used for the player one reveal", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await truffleAssert.reverts(
                rcp.revealPlayerOne(wrongSecretBytes32, ROCK, {from: playerOne}),
                INVALID_STEP_MSG
            );
           
        }).timeout(TIMEOUT);



        it("Call reverts when an invalid move is used for the player one reveal", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await truffleAssert.reverts(
                rcp.revealPlayerOne(playerOneSecretBytes32, 0, {from: playerOne}),
                INVALID_MOVE_MSG
            );

            await truffleAssert.fails(
                rcp.revealPlayerOne(playerOneSecretBytes32, toBN(4), {from: playerOne}),
                truffleAssert.ErrorType.INVALID_OPCODE
            );

        }).timeout(TIMEOUT);
    });

    describe('Player two reveal validation', async function() {

        it("Call reverts when an invalid address calls player two reveal", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, PAPER, {from: playerOne});

            await truffleAssert.reverts(
                rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, SCISSORS, {from: playerThree}),
                HASH_MISMATCH_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when an invalid secret is used for the player two reveal", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await  rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, PAPER, {from: playerOne});

            await truffleAssert.reverts(
                rcp.revealPlayerTwo(gameKey, wrongSecretBytes32, ROCK, {from: playerTwo}),
                HASH_MISMATCH_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when an invalid move is used for the player two reveal", async () => {``

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});

            await truffleAssert.reverts(
                rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, 0, {from: playerTwo}),
                INVALID_MOVE_MSG
            );

            await truffleAssert.fails(
                rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, toBN(4), {from: playerTwo}),
                truffleAssert.ErrorType.INVALID_OPCODE
            );

        }).timeout(TIMEOUT);
    });

    describe('Player collects forfeit validation', async function() {

        beforeEach("Deploy and prepare", async function() {
            const snapShot = await timeMachine.takeSnapshot();
            snapshotId = snapShot['result'];
        });

        afterEach(async() => {
            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("Call reverts when player one collects forfeit before player one reveals", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

            await truffleAssert.reverts(
                rcp.playerOneCollectsForfeit(gameKey, {from: playerOne}),
                INVALID_STEP_MSG
            );
           
        }).timeout(TIMEOUT);

        it("Call reverts when player two tries to collect player one's forfeit", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
            await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

            await truffleAssert.reverts(
                rcp.playerOneCollectsForfeit(gameKey, {from: playerTwo}),
                INVALID_PLAYER_MSG
            );
           
        }).timeout(TIMEOUT);

        it("Call reverts when player one collects forfeit before the game has expired", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, PAPER, {from: playerOne});

            await truffleAssert.reverts(
                rcp.playerOneCollectsForfeit(gameKey, {from: playerOne}),
                GAME_NOT_EXPIRED_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player two collects forfeit after player one reveals", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, SCISSORS, {from: playerOne});
            await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

            await truffleAssert.reverts(
                rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo}),
                INVALID_STEP_MSG
            );
           
        }).timeout(TIMEOUT);

        it("Call reverts when player one tries to collect player two's forfeit", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

            await truffleAssert.reverts(
                rcp.playerTwoCollectsForfeit(gameKey, {from: playerOne}),
                INVALID_PLAYER_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player one collects forfeit before the game has expired", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await truffleAssert.reverts(
                rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo}),
                GAME_NOT_EXPIRED_MSG
            );

        }).timeout(TIMEOUT);
    });

    describe('Player hash creation validation', async function() {

        it("Call reverts when player one creates a move hash with a zero bytes secret", async () => {

            await truffleAssert.reverts(
                rcp.createPlayerOneMoveHash(playerOne, ZERO_BYTES_32, ROCK),
                SECRET_EMPTY_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player one creates a move hash with an invalid move", async () => {

            await truffleAssert.reverts(
                rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, 0),
                INVALID_MOVE_MSG
            );

            await truffleAssert.fails(
                rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, toBN(4)),
                truffleAssert.ErrorType.INVALID_OPCODE
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player two creates a move hash with a zero bytes game key", async () => {

            await truffleAssert.reverts(
                rcp.createPlayerTwoMoveHash(playerOne, ZERO_BYTES_32, playerOneSecretBytes32, ROCK),
                "Game key cannot be empty"
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player two creates a move hash with a zero bytes secret", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);

            await truffleAssert.reverts(
                rcp.createPlayerTwoMoveHash(playerTwo, gameKey, ZERO_BYTES_32, ROCK),
                SECRET_EMPTY_MSG
            );

        }).timeout(TIMEOUT);

        it("Call reverts when player two creates a move hash with an invalid move", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);

            await truffleAssert.reverts(
                rcp.createPlayerTwoMoveHash(playerOne, gameKey, playerTwoSecretBytes32, 0),
                INVALID_MOVE_MSG
            );

            await truffleAssert.fails(
                rcp.createPlayerTwoMoveHash(playerOne, gameKey, playerTwoSecretBytes32, toBN(4)),
                truffleAssert.ErrorType.INVALID_OPCODE
            );

        }).timeout(TIMEOUT);
    });

    describe('Checking pausible functions can be paused', async function() {

        beforeEach("Deploy and prepare", async function() {
            const snapShot = await timeMachine.takeSnapshot();
            snapshotId = snapShot['result'];
        });

        afterEach(async() => {
            await timeMachine.revertToSnapshot(snapshotId);
        });

       it("Player one move is pausable and unpausable", async () => {

           const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);

            await rcp.pause({from: contractOwner});
            await truffleAssert.reverts(
                rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10}),
                "Pausable: paused"
            );

            await rcp.unpause({from: contractOwner});
            const txObj = await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            await truffleAssert.eventEmitted(txObj, 'PlayerOneMoves');

        }).timeout(TIMEOUT);

        it("Player two move is pausable and unpausable", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.pause({from: contractOwner});

            await truffleAssert.reverts(
                rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10}),
                "Pausable: paused"
            );

            await rcp.unpause({from: contractOwner});
            const txObj = await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await truffleAssert.eventEmitted(txObj, 'PlayerTwoMoves');

        }).timeout(TIMEOUT);

        it("Player one reveal is pausable and unpausable", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});

            await rcp.pause({from: contractOwner});

            await truffleAssert.reverts(
                rcp.revealPlayerOne(playerOneSecretBytes32, SCISSORS, {from: playerOne}),
                "Pausable: paused"
            );
            
            await rcp.unpause({from: contractOwner});
            const txObj = await rcp.revealPlayerOne(playerOneSecretBytes32, SCISSORS, {from: playerOne});
            await truffleAssert.eventEmitted(txObj, 'PlayerOneReveals');

        }).timeout(TIMEOUT);

        it("Player two reveal is pausable and unpausable", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, SCISSORS);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, PAPER);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, SCISSORS, {from: playerOne});

            await rcp.pause({from: contractOwner});

            await truffleAssert.reverts(
                rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo}),
                "Pausable: paused"
            );

            await rcp.unpause({from: contractOwner});
            const txObj = await rcp.revealPlayerTwo(gameKey, playerTwoSecretBytes32, PAPER, {from: playerTwo});
            await truffleAssert.eventEmitted(txObj, 'PlayerTwoReveals');

        }).timeout(TIMEOUT);

        it("Player one collecting forfeit is pausable and unpausable", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, ROCK);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, SCISSORS);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await rcp.revealPlayerOne(playerOneSecretBytes32, ROCK, {from: playerOne});
            await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

            await rcp.pause({from: contractOwner});

            await truffleAssert.reverts(
                rcp.playerOneCollectsForfeit(gameKey, {from: playerOne}),
                "Pausable: paused"
            );
            
            await rcp.unpause({from: contractOwner});
            const txObj = await rcp.playerOneCollectsForfeit(gameKey, {from: playerOne});
            await truffleAssert.eventEmitted(txObj, 'ForfeitPaid');
            
        }).timeout(TIMEOUT);

        it("Player two collecting forfeit is pausable and unpausable", async () => {

            const gameKey = await rcp.createPlayerOneMoveHash(playerOne, playerOneSecretBytes32, PAPER);
            await rcp.movePlayerOne(gameKey, "10", {from: playerOne, value: 10});
            const playerTwoMoveHash = await rcp.createPlayerTwoMoveHash(playerTwo, gameKey, playerTwoSecretBytes32, ROCK);
            await rcp.movePlayerTwo(gameKey, playerTwoMoveHash, {from: playerTwo, value: 10});
            await timeMachine.advanceTimeAndBlock(DAY_24_HOUR_IN_SECS);

            await rcp.pause({from: contractOwner});

            await truffleAssert.reverts(
                rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo}),
                "Pausable: paused"
            );
            
            await rcp.unpause({from: contractOwner});
            const txObj = await rcp.playerTwoCollectsForfeit(gameKey, {from: playerTwo});
            await truffleAssert.eventEmitted(txObj, 'ForfeitPaid');
            
        }).timeout(TIMEOUT)
    });
});
