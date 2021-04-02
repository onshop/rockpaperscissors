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
    string private constant INVALID_MOVE_MSG = "Invalid move";
    string private constant INVALID_STEP_MSG = "Invalid step";
    string private constant HASH_MISMATCH_MSG = "Move and secret do not match";
    string private constant GAME_NOT_EXPIRED_MSG = "Game has not expired";
    string private constant SECRET_EMPTY_MSG = "Secret is empty";

    uint256 constant FORFEIT_WINDOW = 1 days;
    
    enum Steps {
        INIT, // 0
        PLAYER_ONE_MOVE, // 1
        PLAYER_TWO_MOVE, // 2
        PLAYER_ONE_REVEAL // 3
    }
    Steps public steps;

    enum Moves {
        DRAW, // 0
        LEFTWIN, // 1
        RIGHTWIN, // 2
        INCORRECT // 3
    }
    Moves public moves;

    struct Game {
        uint256 stake;
        uint256 expiryDate;
        uint8 playerOneMove;
        uint8 step;
        address playerOne;
        address playerTwo;
        bytes32 playerTwoMoveHash;
    }

    event PlayerOneMoves(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 stake,
        uint256 amount
    );

    event PlayerTwoMoves(
        address indexed player,
        uint256 amount,
        bytes32 indexed gameKey,
        bytes32 moveHash,
        uint256 expiryDate
    );

    event PlayerOneReveals(
        address indexed player,
        bytes32 indexed gameKey,
        uint8 move,
        uint256 expiryDate
    );

    event PlayerTwoReveals(
        address indexed player,
        bytes32 indexed gameKey,
        uint8 move
    );

    event DrawRefund(
        address indexed playerOne,
        address indexed playerTwo,
        bytes32 indexed gameKey,
        uint256 playerOneRefund,
        uint256 playerTwoRefund
    );

    event GamePayment(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 amount
    );

    event ForfeitPaid(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 amount
    );

    event WithDraw(
        address indexed player,
        uint amount
    );

    event PlayerOneEndsGame(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 amount
    );

    // The creator's move is embedded in the game key
    function movePlayerOne(bytes32 moveHash, uint256 stake) external payable whenNotPaused {

        require(moveHash != bytes32(0), "Move hash is empty");
        Game storage game = games[moveHash];
        require(game.step == uint8(Steps.INIT), INVALID_STEP_MSG);
        require(game.playerOne == NULL_ADDRESS, INVALID_MOVE_MSG);

        game.stake = stake;
        game.playerOne = msg.sender;
        game.step = uint8(Steps.PLAYER_ONE_MOVE);
        depositStake(stake);

        emit PlayerOneMoves(msg.sender, moveHash, stake, msg.value);
    }

    function movePlayerTwo(bytes32 gameKey, bytes32 moveHash) external payable whenNotPaused {

        require(moveHash != bytes32(0), "Move hash is empty");
        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_MOVE), INVALID_STEP_MSG);

        uint256 expiryDate = block.timestamp.add(FORFEIT_WINDOW);
        game.playerTwo = msg.sender;
        game.playerTwoMoveHash = moveHash;
        game.step = uint8(Steps.PLAYER_TWO_MOVE);
        game.expiryDate = expiryDate;
        depositStake(game.stake);

        emit PlayerTwoMoves(msg.sender, msg.value, gameKey, moveHash, expiryDate);
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

    function revealPlayerOne(bytes32 secret, uint256 playerOneMove) external whenNotPaused {

        require(playerOneMove > 0 && playerOneMove < 4, INVALID_MOVE_MSG);
        bytes32 gameKey = createPlayerOneMoveHash(msg.sender, secret, playerOneMove);
        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_TWO_MOVE), INVALID_STEP_MSG);

        uint256 expiryDate = block.timestamp.add(FORFEIT_WINDOW);
        game.playerOneMove = uint8(playerOneMove);
        game.step = uint8(Steps.PLAYER_ONE_REVEAL);
        game.expiryDate = expiryDate;

        emit PlayerOneReveals(msg.sender, gameKey, uint8(playerOneMove), expiryDate);
    }

    function revealPlayerTwo(bytes32 gameKey, bytes32 secret, uint256 playerTwoMove) external whenNotPaused {

        require(playerTwoMove > 0 && playerTwoMove < 4, INVALID_MOVE_MSG);
        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_REVEAL), INVALID_STEP_MSG);
        address playerTwo = game.playerTwo;

        //Validate move
        bytes32 expectedMoveHash = createPlayerTwoMoveHash(msg.sender, gameKey, secret, playerTwoMove);
        require(game.playerTwoMoveHash == expectedMoveHash, HASH_MISMATCH_MSG);

        emit PlayerTwoReveals(msg.sender, gameKey, uint8(playerTwoMove));

        uint256 stake = game.stake;
        address playerOne = game.playerOne;
        uint256 playerOneMove = uint256(game.playerOneMove);
        address winner;
        address loser;
        uint256 outcome = resolveGame(playerOneMove, playerTwoMove);

        if (outcome == uint256(Moves.DRAW)) {
            resetGame(game);
            balances[playerOne] = balances[playerOne].add(stake);
            balances[playerTwo] = balances[playerTwo].add(stake);
            DrawRefund(playerOne, playerTwo, gameKey, stake, stake);

            return;

        } else if (outcome == uint256(Moves.LEFTWIN)) {
            winner = playerOne;
            loser = playerTwo;
        } else if (outcome == uint256(Moves.RIGHTWIN)) {
            winner = playerTwo;
            loser = playerOne;
        } else {
            revert(INVALID_MOVE_MSG);
        }
        uint256 winnings = stake.mul(2);
        balances[winner] = balances[winner].add(winnings);
        emit GamePayment(winner, gameKey, winnings);

        resetGame(game);
    }

    function resolveGame(uint256 leftPlayer, uint256 rightPlayer) public pure returns(uint256) {

        if (leftPlayer == 0 || leftPlayer > 3 || rightPlayer == 0 || rightPlayer > 3) {
            return uint256(Moves.INCORRECT);
        }

        if (rightPlayer.mod(3) == leftPlayer.sub(1)) {
            return uint256(Moves.LEFTWIN);
        } else if (leftPlayer.mod(3) == rightPlayer.sub(1)) {
            return uint256(Moves.RIGHTWIN);
        }

        return uint256(Moves.DRAW);
    }

    /*
    * If expiry has passed, and player 2 has not revealed then:
    * - Player 1 pays no fee as a compensation
    * - Player 2 is disincentivised by not getting a fee refunded that they would have received if resolved.
    *
    * - If no player joins the game, then player 1 gets back their stake
    */
    function playerOneCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_REVEAL), INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);

        require(block.timestamp >= game.expiryDate, GAME_NOT_EXPIRED_MSG);

        uint256 forfeit = game.stake.mul(2);
        resetGame(game);
        balances[playerOne] = balances[playerOne].add(forfeit);

        emit ForfeitPaid(playerOne, gameKey, forfeit);
    }

    /*
    * If expiry has passed, and player 1 has not revealed
    * They pay no fee as a compensation
    * Player 1 is disincentivised by not getting a fee refunded that would have received if they revealed.
    */
    function playerTwoCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_TWO_MOVE), INVALID_STEP_MSG);
        address playerTwo = game.playerTwo;
        require(msg.sender == playerTwo, INVALID_PLAYER_MSG);
        require(block.timestamp >= game.expiryDate, GAME_NOT_EXPIRED_MSG);

        uint256 forfeit = game.stake.mul(2);
        resetGame(game);
        balances[playerTwo] = balances[playerTwo].add(forfeit);

        emit ForfeitPaid(playerTwo, gameKey, forfeit);
    }

    function playerOneEndsGame(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_MOVE), INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);

        uint256 stake = game.stake;
        resetGame(game);
        balances[playerOne] = balances[playerOne].add(stake);

        emit PlayerOneEndsGame(playerOne, gameKey, stake);
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

    // We don't want to delete the struct so the key cannot be reused
    function resetGame(Game storage game) internal {

        game.stake = 0;
        game.playerTwo = address(0);
        game.playerTwoMoveHash = bytes32(0);
        game.playerOneMove = 0;
        game.expiryDate = 0;
        game.step = 0;
    }

    // This can only be used once because it is used as a mapping key
    function createPlayerOneMoveHash(address player, bytes32 secret, uint256 move) public pure returns(bytes32) {

        require(secret != bytes32(0), SECRET_EMPTY_MSG);
        require(move > 0 && move < 4, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(player, secret, move));
    }

    // Even if the secret is reused, the hash will always be unique because the game key will be unique
    function createPlayerTwoMoveHash(address player, bytes32 gameKey, bytes32 secret, uint256 move) public pure returns (bytes32) {

        require(gameKey != bytes32(0), "Game key cannot be empty");
        require(secret != bytes32(0), SECRET_EMPTY_MSG);
        require(move > 0 && move < 4, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(player, gameKey, secret, move));
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}