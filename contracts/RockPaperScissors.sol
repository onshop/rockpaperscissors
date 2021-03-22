//SPDX-License-Identifier: MIT
pragma solidity >= 0.6.0 < 0.7.0;

import "./access/Ownable.sol";
import "./utils/Pausable.sol";

import {SafeMath} from "./math/SafeMath.sol";

contract RockPaperScissors is Ownable, Pausable {

    using SafeMath for uint;

    mapping(address => uint) public balances;
    mapping(bytes32 => Game) public games;

    address private constant NULL_ADDRESS = address(0);
    string private constant NO_STAKE_TO_WITHDRAW_MSG = "No stake to withdraw";
    string private constant BAD_MATCH_MSG = "Move and secret do not match";
    string private constant ALREADY_MOVED_MSG = "Already moved";
    string private constant INVALID_PLAYER_MSG = "Invalid player";
    string private constant GAME_NOT_FOUND_MSG = "Game not found";
    string private constant GAME_IN_PROGRESS_MSG = "Game in progress";

    struct Game {
        address playerOne;
        address playerTwo;
        uint256 stake;
        bytes32 playerOneMoveHash;
        bytes32 playerTwoMoveHash;
        uint8 playerOneMove;
        uint8 playerTwoMove;
    }

    event Deposit(
        address player,
        uint256 amount
    );

    event GameInitialised(
        address indexed initiator,
        bytes32 indexed token,
        address playerOne,
        address playerTwo,
        uint256 stake
    );

    event PlayerMove(
        address indexed player,
        bytes32 indexed token
    );

    event Draw(
        bytes32 indexed token
    );

    event AllPlayersMoved(
        bytes32 indexed token
    );

    event AllMovesRevealed(
        bytes32 indexed token
    );

    event WinnerRewarded(
        bytes32 indexed token,
        address indexed winner,
        uint256 winnings
    );

    event WithDraw(
        address indexed withdrawer,
        uint amount
    );

    event  PlayerWithdraws(
        address indexed player,
        bytes32 indexed token,
        uint256 refund
    );

    uint8 constant ROCK = 1;
    uint8 constant PAPER = 2;
    uint8 constant SCISSORS = 3;

    function deposit() external payable whenNotPaused {

        balances[msg.sender] = balances[msg.sender].add(msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    function initialise(bytes32 gameToken, address playerOne, address playerTwo, uint stake) external whenNotPaused onlyOwner {

        require(playerOne != msg.sender, "Caller cannot be player one");
        require(playerTwo != msg.sender, "Caller cannot be player two");
        require(playerOne != address(0), "Player one cannot be empty");
        require(playerTwo != address(0), "Player two cannot be empty");
        require(playerOne != playerTwo, "Player one and two are the same");

        Game storage game = games[gameToken];

        game.playerOne = playerOne;
        game.playerTwo = playerTwo;
        game.stake = stake;

        emit GameInitialised(msg.sender, gameToken, playerOne, playerTwo, stake);
    }

    function play(bytes32 gameToken, bytes32 playerMoveHash) public whenNotPaused {

        require(gameToken != bytes32(0), "Game token cannot be empty");
        require(playerMoveHash != bytes32(0), "Move token cannot be empty");

        Game storage game = games[gameToken];

        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        uint256 stakerBalance = balances[msg.sender];
        require(stakerBalance >= stake, "Insufficient funds to play");

        if (msg.sender == game.playerOne) {
            require(game.playerOneMoveHash == bytes32(0), ALREADY_MOVED_MSG);
            game.playerOneMoveHash = playerMoveHash;
        }
        if (msg.sender == game.playerTwo) {
            require(game.playerTwoMoveHash == bytes32(0), ALREADY_MOVED_MSG);
            game.playerTwoMoveHash = playerMoveHash;
        }

        emit PlayerMove(msg.sender, gameToken);

        if(game.playerOneMoveHash != bytes32(0) && game.playerTwoMoveHash != bytes32(0)){
            emit AllPlayersMoved(gameToken);
        }

        balances[msg.sender] = SafeMath.sub(stakerBalance, stake);
    }

    function revealPlayerMove(bytes32 gameToken, bytes32 secret, uint8 playerMove) external whenNotPaused {
        Game storage game = games[gameToken];

        address playerOne = game.playerOne;
        address playerTwo= game.playerTwo;

        require(msg.sender == playerOne || msg.sender == playerTwo, INVALID_PLAYER_MSG);
        require(playerMove > 0 && playerMove < 4, "Invalid move");

        bytes32 playerOneMoveHash = game.playerOneMoveHash;
        bytes32 playerTwoMoveHash= game.playerTwoMoveHash;

        require(playerOneMoveHash != bytes32(0) && playerTwoMoveHash != bytes32(0), GAME_IN_PROGRESS_MSG);

        bytes32 expectedMoveHash = hashPlayerMove(gameToken, msg.sender, secret, playerMove);

        if (msg.sender == playerOne) {
            require(playerOneMoveHash == expectedMoveHash, BAD_MATCH_MSG);
            game.playerOneMove = playerMove;
        }

        if (msg.sender == playerTwo) {
            require(playerTwoMoveHash == expectedMoveHash, BAD_MATCH_MSG);
            game.playerTwoMove = playerMove;
        }

        if (game.playerOneMove != 0 && game.playerTwoMove != 0) {
            emit AllMovesRevealed(gameToken);
        }
    }

    function determineWinner(bytes32 gameToken) external onlyOwner whenNotPaused {
        Game storage game = games[gameToken];
        require(game.stake != 0, GAME_NOT_FOUND_MSG);

        if(game.playerOneMove == game.playerTwoMove){
            resetGame(game);
            emit Draw(gameToken);
            return;
        }

        address winner;

        if (isWinningMove(game.playerOneMove, game.playerTwoMove)) {
            winner = game.playerOne;
        } else {
            winner = game.playerTwo;
        }

        uint winnings = game.stake * 2;
        resetGame(game);
        emit WinnerRewarded(gameToken, winner, winnings);

        balances[winner] = balances[winner].add(winnings);
    }

    function isWinningMove(uint8 playerOneMove, uint8 playerTwoMove) internal pure returns (bool) {

        if (playerOneMove == ROCK && playerTwoMove == SCISSORS) {
            return true;
        }
        if (playerOneMove == PAPER && playerTwoMove == ROCK) {
            return true;
        }
        if (playerOneMove == SCISSORS && playerTwoMove == PAPER) {
            return true;
        }

        return false;
    }

    function withdraw(uint amount) external whenNotPaused returns(bool success) {
        uint256 withdrawerBalance = balances[msg.sender];
        require(amount > 0, "The value must be greater than 0");
        require(withdrawerBalance >= amount, "There are insufficient funds");

        emit WithDraw(msg.sender, amount);

        balances[msg.sender] = SafeMath.sub(withdrawerBalance, amount);
        (success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function withDrawFromGame(bytes32 gameToken) whenNotPaused external whenNotPaused {
        Game storage game = games[gameToken];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        if (msg.sender == game.playerOne) {
            require(game.playerTwoMoveHash == bytes32(0), GAME_IN_PROGRESS_MSG);
            require(game.playerOneMoveHash != bytes32(0), NO_STAKE_TO_WITHDRAW_MSG);
        }

        if (msg.sender == game.playerTwo) {
            require(game.playerOneMoveHash == bytes32(0), GAME_IN_PROGRESS_MSG);
            require(game.playerTwoMoveHash != bytes32(0), NO_STAKE_TO_WITHDRAW_MSG);
        }

        emit PlayerWithdraws(msg.sender, gameToken, stake);
        resetGame(game);

        balances[msg.sender] = balances[msg.sender].add(stake);
    }

    function resetGame(Game storage game) internal {
        game.stake = 0;
        game.playerOneMove = 0;
        game.playerTwoMove = 0;
        game.playerOneMoveHash = bytes32(0);
        game.playerTwoMoveHash = bytes32(0);
    }

    function createGameToken(address playerOne, address playerTwo) external view returns (bytes32){
        require(playerOne != NULL_ADDRESS, "1st address cannot be zero");
        require(playerTwo != NULL_ADDRESS, "2nd address cannot be zero");

        return keccak256(abi.encodePacked(playerOne, playerTwo, address(this)));
    }

    function hashPlayerMove(bytes32 gameToken, address player, bytes32 secret, uint playerMove) public view returns (bytes32) {
        require(secret != bytes32(0), "Secret cannot be empty");
        require(player != NULL_ADDRESS, "Address cannot be zero");

        return keccak256(abi.encodePacked(gameToken, player, secret, playerMove, address(this)));
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}