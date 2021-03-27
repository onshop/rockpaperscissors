//SPDX-License-Identifier: MIT
pragma solidity >= 0.6.0 < 0.7.0;

import "./access/Ownable.sol";
import "./utils/Pausable.sol";

import {SafeMath} from "./math/SafeMath.sol";

contract RockPaperScissors is Ownable, Pausable {

    using SafeMath for uint256;

    mapping(address => uint256) public balances;
    mapping(bytes32 => Game) public games;

    address private constant NULL_ADDRESS = address(0);
    string private constant INVALID_PLAYER_MSG = "Invalid player";
    string private constant GAME_NOT_FOUND_MSG = "Game not found";
    string private constant INVALID_MOVE_MSG = "Invalid move";
    string private constant INVALID_STEP_MSG = "Invalid step";

    uint256 constant FORFEIT_WINDOW = 12 hours;
    uint256 constant FEE_PERCENTAGE = 10;

    enum Steps {
        INIT,
        PLAYER_ONE_MOVE,
        PLAYER_TWO_MOVE,
        PLAYER_ONE_REVEAL,
        PLAYER_TWO_REVEAL,
        END
    }

    struct Game {
        uint256 stake;
        address playerOne;
        address playerTwo;
        uint8 playerTwoMoveHash;
        uint8 playerOneMove;
        uint8 playerTwoMove;
        uint256 expiryDate;
        uint8 step;
    }

    event PlayerOneMoves(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 value
    );

    event PlayerTwoMoves(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 value
    );

    event PlayerTwoReveals(
        address indexed player,
        bytes32 indexed gameKey,
        uint8 move
    );

    event WinnerRewarded(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 amount
    );

    event  ForfeitPaid(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 amount
    );

    event WithDraw(
        address indexed withdrawer,
        uint amount
    );

    // The creator's move is embedded in the game key
    function playerOneMove(bytes32 gameKey, uint stake) external payable whenNotPaused {

        require(gameKey != bytes32(0), "Game key cannot be empty");
        require(stake > 0, "Stake cannot be zero");

        Game storage game = games[gameKey];
        require(game.step == Steps.INIT, INVALID_STEP_MSG);

        game.playerOne = msg.sender;
        game.stake = stake;
        game.step = Steps.PLAYER_ONE_MOVE;
        depositStake(stake);

        emit PlayerOneMoves(msg.sender, gameKey, stake);
    }

    /*
    * The opponent joins the game
    */
    function playerTwoMove(bytes32 gameKey, bytes32 moveHash) external payable whenNotPaused {

        Game storage game = games[gameKey];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(game.step == Steps.PLAYER_ONE_MOVE, INVALID_STEP_MSG);

        game.playerTwo = msg.sender;
        game.playerTwoMoveHash = moveHash;
        game.step = steps.PLAYER_TWO_MOVE;
        depositStake(stake);

        emit PlayerTwoMoves(msg.sender, msg.value, gameKey);
    }

    function depositStake(uint256 stake) internal {
        uint256 senderBalance = balances[msg.sender];

        if (msg.value == stake) {
            return;
        }

        if (msg.value < stake) {
            require(senderBalance >= stake.sub(msg.value), "Insufficient balance");
            balances[msg.sender] = senderBalance.sub(stake.sub(msg.value));
        } else {
            balances[msg.sender] = senderBalance.add(msg.value.sub(stake));
        }

        Deposit(msg.sender, msg.value);
    }

    function playerOneReveal(bytes32 gameKey, bytes32 secret, uint8 move) external whenNotPaused {

        require(move < 3, INVALID_MOVE_MSG);
        Game storage game = games[gameKey];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(game.step == Steps.PLAYER_TWO_MOVE, INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, ONLY_PLAYER_ONE_CALL_MSG);


        //Validate move
        bytes32 expectedMoveHash = createGameKey(secret, move);
        require(gameKey == expectedMoveHash, "Move and secret do not match");

        game.playerOneMove = move;
        game.step = Steps.PLAYER_ONE_REVEAL;
    }

    /**
    * Once the opponent has made their move, the creator of the game must resolve to determine the winner
    * and reward the winner.
    * If the creator does not resolve the game then the opponent can collect their winnings
     * after the forfeit window has expired.
    */
    function playerTwoReveal(bytes32 gameKey, bytes32 secret, uint8 playerTwoMove) external whenNotPaused {

        Game storage game = games[gameKey];
        uint256 stake = game.stake;
        require(game.step == Steps.PLAYER_ONE_REVEAL, INVALID_STEP_MSG);
        address playerTwo = game.playerTwo;
        require(msg.sender == playerTwo, INVALID_PLAYER_MSG);
        require(playerTwoMove < 3, INVALID_MOVE_MSG);

        //Validate move
        bytes32 expectedMoveHash = createOpponentMoveHash(gameKey, secret, playerTwoMove);
        require(game.playerTwoMoveHash == expectedMoveHash, "Move and secret do not match");

        uint8 playerOneMove = game.playerOneMove;


        //Draw
        if(playerOneMove == playerTwoMove){
            resetGame(game);
            balances[playerOne] = balances[playerOne].add(stake);
            balances[playerTwo] = balances[playerTwo].add(stake);
            emit Draw(gameKey);
            return;
        }

        //Determine winner
        address winner;
        address loser;
        uint256 winnings = SafeMath.mul(stake, 2);

        // If the creator wins then is rewarded by not paying a fee on the winnings
        if (isWinner(playerOneMove, opponentMove)) {
            winner = playerOne;
            loser = playerTwo;
        } else {
            winner = playerTwo;
            loser = playerTwo;
        }
        balances[winner] = balances[winner].add(winnings);
        resetGame(game);

        emit WinnerRewarded(gameKey, winner, amount);
    }

    function isWinner(uint8 creatorMove, uint8 opponentMove) internal pure returns (boolean) {
        return (mod(opponentMove.add(1), 3) == creatorMove);
    }

    /*
    * If expiry has passed, the opponent forfeits their stake
    * They also pay no fee as a compensation
    * Creator punished by not getting a fee refunded that would have received if resolved
    */
    function playerOneCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {
        Game storage game = games[gameKey];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(game.step == Steps.PLAYER_ONE_REVEAL, INVALID_STEP_MSG);
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);
        require(block.timestamp >= game.expiryDate, "Game has not expired");

        address playerTwo = game.playerTwo;
        uint256 forfeit = SafeMath.mul(stake, 2);
        resetGame(game);
        balances[playerOne] = balances[playerOne].add(forfeit);

        emit ForfeitPaid(opponent, gameKey, forfeit);
    }

    function playerTwoCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {
        Game storage game = games[gameKey];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(game.step == Steps.PLAYER_TWO_MOVE, INVALID_STEP_MSG);
        require(msg.sender == playerTwo, INVALID_PLAYER_MSG);
        require(block.timestamp >= game.expiryDate, "Game has not expired");

        address playerTwo = game.playerTwo;
        uint256 forfeit = SafeMath.mul(stake, 2);
        resetGame(game);
        balances[playerTwo] = balances[playerTwo].add(forfeit);

        emit ForfeitPaid(opponent, gameKey, forfeit);
    }

    function withdraw(uint amount) external whenNotPaused returns(bool success) {
        uint256 withdrawerBalance = balances[msg.sender];
        require(amount > 0, "The value must be greater than 0");
        require(withdrawerBalance >= amount, "There are insufficient funds");

        balances[msg.sender] = withdrawerBalance.sub(amount);
        emit WithDraw(msg.sender, amount);

        (success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function resetGame(Game storage game) internal {
        game.stake = 0;
        game.moveHash = bytes32(0);
        game.opponentMove = 0;
        game.expiryDate = 0;
    }

    // This can only be used once because it is used as a mapping key
    function createGameKey(bytes32 secret, uint move) public view returns (bytes32) {
        require(gameKey != bytes32(0), "Game token cannot be empty");
        require(secret != bytes32(0), "Secret cannot be empty");
        require(move < 3, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(msg.sender, secret, move));
    }

    // Even if the secret is reused, the hash will always be unique because the game key will be unique
    function createOpponentMoveHash(bytes32 gameKey, bytes32 secret, uint move) public view returns (bytes32) {
        require(gameKey != bytes32(0), "Game token cannot be empty");
        require(secret != bytes32(0), "Secret cannot be empty");
        require(move < 3, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(msg.sender, gameKey, secret, move));
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}