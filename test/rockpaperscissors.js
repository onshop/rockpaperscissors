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

    const [contractOwner, gameManager, playerOne, playerTwo] = accounts;
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
        gameToken = await soliditySha3(playerOne, playerTwo);
        playerOneMoveHash = await rcp.hashPlayerMove(gameToken, playerOne, playerOneSecretBytes32, rock);
        playerTwoMoveHash = await rcp.hashPlayerMove(gameToken, playerTwo, playerTwoSecretBytes32, scissors);
    });


});
