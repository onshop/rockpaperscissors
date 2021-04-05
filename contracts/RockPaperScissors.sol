//SPDX-License-Identifier: MIT
pragma solidity >= 0.6.0 < 0.7.0;

import "./access/Ownable.sol";
import "./utils/Pausable.sol";

import {SafeMath} from "./math/SafeMath.sol";

contract RockPaperScissors is Ownable, Pausable {

    using SafeMath for uint8;
    using SafeMath for uint256;

    mapping(address => uint256) public balances;
    mapping(bytes32 => Game) public games;

    address private constant NULL_ADDRESS = address(0);
    string private constant INVALID_PLAYER_MSG = "Invalid player";
    string private constant INVALID_MOVE_MSG = "Invalid move";
    string private constant INVALID_STEP_MSG = "Invalid step";
    string private constant HASH_MISMATCH_MSG = "Move and secret do not match";
    string private constant GAME_NOT_EXPIRED_MSG = "Game has not expired";
    string private constant SECRET_EMPTY_MSG = "Secret is empty";

    uint256 constant FORFEIT_WINDOW = 1 days;
    
    enum Steps {
        UNSTARTED, // 0
        PLAYER_ONE_MOVED, // 1
        PLAYER_TWO_MOVED, // 2
        PLAYER_ONE_REVEALED // 3
    }
    Steps public steps;

    enum GameResult {
        DRAW, // 0
        LEFTWIN, // 1
        RIGHTWIN, // 2
        INCORRECT // 3
    }
    GameResult public gameResult;

    enum Moves {
        EMPTY, // 0
        ROCK, // 1
        PAPER, // 2
        SCISSORS // 3
    }

    Moves public moves;

    struct Game {
        Steps step;
        address playerOne;
        Moves playerOneMove;
        uint256 stake;
        uint256 expiryDate;
        address playerTwo;
        bytes32 playerTwoMoveHash;
    }

    event PlayerOneMoves(
        bytes32 indexed gameKey,
        address indexed player,
        uint256 stake,
        uint256 amount
    );

    event PlayerTwoMoves(
        bytes32 indexed gameKey,
        address indexed player,
        uint256 amount,
        bytes32 moveHash,
        uint256 expiryDate
    );

    event PlayerOneReveals(
        bytes32 indexed gameKey,
        address indexed player,
        Moves move,
        uint256 expiryDate
    );

    event PlayerTwoReveals(
        bytes32 indexed gameKey,
        address indexed player,
        Moves move
    );

    event DrawRefund(
        bytes32 indexed gameKey,
        address indexed playerOne,
        address indexed playerTwo,
        uint256 playerOneRefund,
        uint256 playerTwoRefund
    );

    event GamePayment(
        bytes32 indexed gameKey,
        address indexed player,
        uint256 amount
    );

    event ForfeitPaid(
        bytes32 indexed gameKey,
        address indexed player,
        uint256 amount
    );

    event WithDraw(
        address indexed player,
        uint amount
    );

    event PlayerOneEndsGame(
        bytes32 indexed gameKey,
        address indexed player,
        uint256 amount
    );

    // The creator's move is embedded in the game key
    function movePlayerOne(bytes32 gameKey, uint256 stake) external payable whenNotPaused {

        require(gameKey != bytes32(0), "Game key hash is empty");
        Game storage game = games[gameKey];
        require(game.step == Steps.UNSTARTED, INVALID_STEP_MSG);
        require(game.playerOne == NULL_ADDRESS, INVALID_MOVE_MSG);

        game.stake = stake;
        game.playerOne = msg.sender;
        game.step = Steps.PLAYER_ONE_MOVED;
        depositStake(stake);

        emit PlayerOneMoves(gameKey, msg.sender, stake, msg.value);
    }

    function movePlayerTwo(bytes32 gameKey, bytes32 moveHash) external payable whenNotPaused {

        require(moveHash != bytes32(0), "Move hash is empty");
        Game storage game = games[gameKey];
        require(game.step == Steps.PLAYER_ONE_MOVED, INVALID_STEP_MSG);

        uint256 expiryDate = block.timestamp.add(FORFEIT_WINDOW);
        game.playerTwo = msg.sender;
        game.playerTwoMoveHash = moveHash;
        game.step = Steps.PLAYER_TWO_MOVED;
        game.expiryDate = expiryDate;
        depositStake(game.stake);

        emit PlayerTwoMoves(gameKey, msg.sender, msg.value, moveHash, expiryDate);
    }

    function depositStake(uint256 stake) internal {

        if (msg.value == stake) {
            return;
        }

        uint256 senderBalance = balances[msg.sender];
        if (msg.value < stake) {
            require(senderBalance >= stake.sub(msg.value), "Insufficient balance");
        }

        balances[msg.sender] = senderBalance.add(msg.value).sub(stake);
    }

    function revealPlayerOne(bytes32 secret, Moves playerOneMove) external whenNotPaused {

        require(playerOneMove >= Moves.ROCK, INVALID_MOVE_MSG);
        bytes32 gameKey = createPlayerOneMoveHash(msg.sender, secret, Moves(playerOneMove));
        Game storage game = games[gameKey];

        require(game.step == Steps.PLAYER_TWO_MOVED, INVALID_STEP_MSG);
        game.step = Steps.PLAYER_ONE_REVEALED;

        uint256 expiryDate = block.timestamp.add(FORFEIT_WINDOW);
        game.expiryDate = expiryDate;

        game.playerOneMove = Moves(playerOneMove);

        emit PlayerOneReveals(gameKey, msg.sender, playerOneMove, expiryDate);
    }

    function revealPlayerTwo(bytes32 gameKey, bytes32 secret, Moves playerTwoMove) external whenNotPaused {

        require(playerTwoMove >= Moves.ROCK, INVALID_MOVE_MSG);
        Game storage game = games[gameKey];
        require(game.step == Steps.PLAYER_ONE_REVEALED, INVALID_STEP_MSG);
        address playerTwo = game.playerTwo;

        //Validate move
        bytes32 expectedMoveHash = createPlayerTwoMoveHash(msg.sender, gameKey, secret, playerTwoMove);
        require(game.playerTwoMoveHash == expectedMoveHash, HASH_MISMATCH_MSG);

        emit PlayerTwoReveals(gameKey, msg.sender, Moves(playerTwoMove));

        uint256 stake = game.stake;
        address playerOne = game.playerOne;
        address winner;
        address loser;
        GameResult outcome = resolveGame(game.playerOneMove, playerTwoMove);

        if (outcome == GameResult.DRAW) {
            resetGame(game);
            balances[playerOne] = balances[playerOne].add(stake);
            balances[playerTwo] = balances[playerTwo].add(stake);
            DrawRefund(gameKey, playerOne, playerTwo, stake, stake);

            return;

        } else if (outcome == GameResult.LEFTWIN) {
            winner = playerOne;
            loser = playerTwo;
        } else if (outcome == GameResult.RIGHTWIN) {
            winner = playerTwo;
            loser = playerOne;
        } else {
            assert(outcome == GameResult.RIGHTWIN);
        }
        uint256 winnings = stake.mul(2);
        balances[winner] = balances[winner].add(winnings);
        emit GamePayment(gameKey, winner, winnings);

        resetGame(game);
    }

    function resolveGame(Moves leftPlayer, Moves rightPlayer) public pure returns(GameResult) {

        if (leftPlayer == Moves.EMPTY || rightPlayer == Moves.EMPTY){
            return GameResult.INCORRECT;
        }

        return GameResult((uint8(leftPlayer).add(3).sub(uint8(rightPlayer))).mod(3));
    }

    function playerOneCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == Steps.PLAYER_ONE_REVEALED, INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);
        require(block.timestamp >= game.expiryDate, GAME_NOT_EXPIRED_MSG);

        uint256 forfeit = game.stake.mul(2);
        resetGame(game);
        balances[playerOne] = balances[playerOne].add(forfeit);

        emit ForfeitPaid(gameKey, playerOne, forfeit);
    }

    function playerTwoCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == Steps.PLAYER_TWO_MOVED, INVALID_STEP_MSG);
        address playerTwo = game.playerTwo;
        require(msg.sender == playerTwo, INVALID_PLAYER_MSG);
        require(block.timestamp >= game.expiryDate, GAME_NOT_EXPIRED_MSG);

        uint256 forfeit = game.stake.mul(2);
        resetGame(game);
        balances[playerTwo] = balances[playerTwo].add(forfeit);

        emit ForfeitPaid(gameKey, playerTwo, forfeit);
    }

    function playerOneEndsGame(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == Steps.PLAYER_ONE_MOVED, INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);

        uint256 stake = game.stake;
        resetGame(game);
        balances[playerOne] = balances[playerOne].add(stake);

        emit PlayerOneEndsGame(gameKey, playerOne, stake);
    }

    function withdraw(uint amount) external whenNotPaused returns(bool success) {

        uint256 withdrawerBalance = balances[msg.sender];
        require(amount > 0, "The value must be greater than 0");

        balances[msg.sender] = withdrawerBalance.sub(amount);
        emit WithDraw(msg.sender, amount);

        (success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    // We don't want to delete the struct so the key cannot be reused
    function resetGame(Game storage game) internal {

        game.stake = 0;
        game.playerTwo = address(0);
        game.playerTwoMoveHash = bytes32(0);
        game.playerOneMove = Moves.EMPTY;
        game.expiryDate = 0;
        game.step = Steps.UNSTARTED;
    }

    // This can only be used once because it is used as a mapping key
    function createPlayerOneMoveHash(address player, bytes32 secret, Moves move) public pure returns(bytes32) {

        require(secret != bytes32(0), SECRET_EMPTY_MSG);
        require(move > Moves.EMPTY, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(player, secret, move));
    }

    // Even if the secret is reused, the hash will always be unique because the game key will be unique
    function createPlayerTwoMoveHash(address player, bytes32 gameKey, bytes32 secret, Moves move) public pure returns (bytes32) {

        require(gameKey != bytes32(0), "Game key cannot be empty");
        require(secret != bytes32(0), SECRET_EMPTY_MSG);
        require(Moves(move) > Moves.EMPTY, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(player, gameKey, secret, move));
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}