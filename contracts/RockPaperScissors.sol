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
    string private constant GAME_NOT_FOUND_MSG = "Game not found";
    string private constant INVALID_MOVE_MSG = "Invalid move";
    string private constant INVALID_STEP_MSG = "Invalid step";
    string private constant HASH_MISMATCH_MSG = "Move and secret do not match";
    string private constant GAME_NOT_EXPIRED_MSG = "Game has not expired";

    uint256 constant FORFEIT_WINDOW = 24 hours;
    uint256 constant FEE_PERCENTAGE = 10;

    enum Steps {
        INIT,
        PLAYER_ONE_MOVE,
        PLAYER_TWO_MOVE,
        PLAYER_ONE_REVEAL,
        PLAYER_TWO_REVEAL,
        RESET
    }

    struct Game {
        uint256 stake;
        address playerOne;
        address playerTwo;
        bytes32 playerTwoMoveHash;
        uint8 playerOneMove;
        uint256 expiryDate;
        uint8 step;
    }

    event PlayerMoves(
        address indexed player,
        bytes32 indexed gameKey,
        uint256 value
    );

    event PlayerReveals(
        address indexed player,
        bytes32 indexed gameKey,
        uint8 move
    );

    event  DrawRefund(
        address indexed playerOne,
        address indexed playerTwo,
        bytes32 indexed gameKey,
        uint256 amount
    );

    event GamePayment(
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
    function movePlayerOne(bytes32 moveHash, uint stake) external payable whenNotPaused {

        require(moveHash != bytes32(0), "Game key cannot be empty");
        Game storage game = games[moveHash];
        require(game.step == uint8(Steps.INIT), INVALID_STEP_MSG);
        require(game.playerOne == NULL_ADDRESS, INVALID_PLAYER_MSG);

        game.playerOne = msg.sender;
        game.stake = game.stake;
        game.step = uint8(Steps.PLAYER_ONE_MOVE);
        depositStake(stake);

        emit PlayerMoves(msg.sender, moveHash, stake);
    }

    function movePlayerTwo(bytes32 gameKey, bytes32 moveHash) external payable whenNotPaused {

        require(moveHash != bytes32(0), "Game key cannot be empty");
        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_MOVE), INVALID_STEP_MSG);
        require(game.playerTwo == NULL_ADDRESS, INVALID_STEP_MSG);

        game.playerTwo = msg.sender;
        game.playerTwoMoveHash = moveHash;
        game.step = uint8(Steps.PLAYER_TWO_MOVE);
        game.expiryDate = block.timestamp + FORFEIT_WINDOW;
        depositStake(game.stake);

        emit PlayerMoves(msg.sender, gameKey, msg.value);
    }

    function depositStake(uint256 stake) internal {

        if (msg.value == stake) {
            return;
        }
        uint256 senderBalance = balances[msg.sender];

        if (msg.value < stake) {
            require(senderBalance >= stake.sub(msg.value), "Insufficient balance");
            balances[msg.sender] = senderBalance.sub(stake.sub(msg.value));
        } else {
            balances[msg.sender] = senderBalance.add(msg.value).sub(stake);
        }
    }

    function revealPlayerOne(bytes32 secret, uint8 playerOneMove) external whenNotPaused {

        bytes32 gameKey = createPlayerOneMoveHash(secret, playerOneMove);
        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_TWO_MOVE), INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);

        game.playerOneMove = playerOneMove;
        game.step = uint8(Steps.PLAYER_ONE_REVEAL);
        game.expiryDate = block.timestamp + FORFEIT_WINDOW;

        emit PlayerReveals(msg.sender, gameKey, playerOneMove);
    }

    function revealPlayerTwo(bytes32 gameKey, bytes32 secret, uint8 playerTwoMove) external whenNotPaused {

        require(playerTwoMove < 3, INVALID_MOVE_MSG);
        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_REVEAL), INVALID_STEP_MSG);
        address playerTwo = game.playerTwo;
        require(msg.sender == playerTwo, INVALID_PLAYER_MSG);

        //Validate move
        bytes32 expectedMoveHash = createPlayerTwoMoveHash(gameKey, secret, playerTwoMove);
        require(game.playerTwoMoveHash == expectedMoveHash, HASH_MISMATCH_MSG);

        emit PlayerReveals(msg.sender, gameKey, playerTwoMove);

        uint256 stake = game.stake;
        address playerOne = game.playerOne;
        uint8 playerOneMove = game.playerOneMove;

        //Draw
        if (playerOneMove == playerTwoMove){
            resetGame(game);
            balances[playerOne] = balances[playerOne].add(stake);
            balances[playerTwo] = balances[playerTwo].add(stake);
            DrawRefund(playerOne, playerTwo, gameKey, stake);

            return;
        }

        //Determine and reward winner
        address winner;
        address loser;
        uint256 fee = stake.mul(FEE_PERCENTAGE.div(100));

        if (isWinner(playerOneMove, playerTwoMove)) {
            winner = playerOne;
            loser = playerTwo;
        } else {
            winner = playerTwo;
            loser = playerOne;
        }
        uint256 winnings = stake.mul(2).sub(fee);
        balances[winner] = balances[winner].add(winnings);
        emit GamePayment(winner, gameKey, winnings);

        balances[loser] = balances[loser].add(fee);
        emit GamePayment(loser, gameKey, fee);

        resetGame(game);
    }

    function isWinner(uint8 playerOneMove, uint8 playerTwoMove) public pure returns (bool) {
        return SafeMath.mod(playerTwoMove.add(1), 3) == playerOneMove;
    }

    /*
    * If expiry has passed, and player 2 has not revealed then:
    * - Player 1 pays no fee as a compensation
    * - Player 2 is punished by not getting a fee refunded that they would have received if resolved.
    *
    * - If no player joins the game, then player 1 gets back their stake
    */
    function playerOneCollectsForfeit(bytes32 gameKey) whenNotPaused external whenNotPaused {
        Game storage game = games[gameKey];
        require(game.step <= uint8(Steps.PLAYER_ONE_REVEAL), INVALID_STEP_MSG);
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
    * Player 1 is punished by not getting a fee refunded that would have received if they revealed.
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

    function playerOneTerminates(bytes32 gameKey) whenNotPaused external whenNotPaused {

        Game storage game = games[gameKey];
        require(game.step == uint8(Steps.PLAYER_ONE_MOVE), INVALID_STEP_MSG);
        address playerOne = game.playerOne;
        require(msg.sender == playerOne, INVALID_PLAYER_MSG);

        resetGame(game);
        balances[playerOne] = balances[playerOne].add(game.stake);

        emit (playerOne, gameKey, forfeit);
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
        game.playerTwoMoveHash = bytes32(0);
        game.playerOneMove = 0;
        game.expiryDate = 0;
        game.step = uint8(Steps.RESET);
    }

    // This can only be used once because it is used as a mapping key
    function createPlayerOneMoveHash(bytes32 secret, uint move) public view returns(bytes32) {

        require(secret != bytes32(0), "Secret cannot be empty");
        require(move < 3, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(msg.sender, secret, move));
    }

    // Even if the secret is reused, the hash will always be unique because the game key will be unique
    function createPlayerTwoMoveHash(bytes32 gameKey, bytes32 secret, uint move) public view returns (bytes32) {
        require(gameKey != bytes32(0), "Game key cannot be empty");
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