//SPDX-License-Identifier: MIT
pragma solidity >= 0.6.0 < 0.7.0;

import "access/Ownable.sol";
import "utils/Pausable.sol";

contract RockPaperScissors is Ownable, Pausable {

    using SafeMath for uint;

    mapping(address => uint) public balances;
    mapping(bytes32 => Game) public games;

    address private constant NULL_ADDRESS = address(0);
    string private constant OPPONENT_ALREADY_STAKED_MSG = "Opponent has already staked";
    string private constant NO_STAKE_TO_WITHDRAW_MSG = "No stake to withdraw";
    string private constant BAD_MATCH_MSG = "Move and secret do not match";
    string private constant STAKE_NOT_RECEIVED_MSG = "Stake payment not received";
    string private constant MOVE_RECEIVED_MSG = "Move already received";
    string private constant INVALID_PLAYER_MSG = "Invalid player";
    string private constant GAME_NOT_FOUND_MSG = "Game not found";

    struct Game {
        address playerOne;
        address playerTwo;
        uint256 stake;
        bool playerOneStaked;
        bool playerTwoStaked;
        bytes32 playerOneMoveHash;
        bytes32 playerTwoMoveHash;
        uint8 playerOneMove;
        uint8 playerTwoMove;
        address winner;
    }

    event GameInitialised(
        bytes32 indexed hash,
        address playerOne,
        address playerTwo,
        uint256 stake
    );

    event DepositStake(
        address indexed player,
        bytes32 indexed hash,
        uint256 amount
    );

    event PlayerMove(
        address indexed player,
        bytes32 indexed hash,
        bytes32 playerMove
    );

    event GameCompleted(
        bytes32 indexed hash
    );

    event WinnerRewarded(
        bytes32 indexed hash,
        address indexed winner,
        uint256 winnings
    );

    event WithDraw(
        address indexed withdrawer,
        uint amount
    );

    uint8 constant ROCK = 1;
    uint8 constant PAPER = 2;
    uint8 constant SCISSORS = 3;

    function deposit() external payable whenNotPaused {

        balances[msg.sender] = balances[msg.sender].add(msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    function initialise(bytes32 gameHash, address playerOne, address playerTwo, uint stake) external whenNotPaused onlyOwner {

        require(playerOne != msg.sender, "Caller cannot be player one");
        require(playerTwo != msg.sender, "Caller cannot be player two");
        require(playerOne != address(0), "Player one cannot be empty");
        require(playerTwo != address(0), "Player two cannot be empty");
        require(playerOne != playerTwo, "Player one and two are the same");

        Game storage game = games[gameHash];

        game.playerOne = playerOne;
        game.playerTwo = playerTwo;
        game.stake = stake;

        emit GameInitialised(gameHash, playerOne, playerTwo, stake);
    }


    function depositStake(bytes32 gameHash) external whenNotPaused {

        Game storage game = games[gameHash];

        require(game.stake != 0, GAME_NOT_FOUND_MSG);
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        uint256 stakerBalance = balances[msg.sender];
        require(stakerBalance >= game.stake, "There are insufficient funds");

        if (game.playerOne == msg.sender) {
            game.playerOneStaked = true;
        } else if (game.playerTwo == msg.sender) {
            game.playerTwoStaked = true;
        }

        balances[msg.sender] = SafeMath.sub(stakerBalance, stake);

        emit DepositStake(msg.sender, gameHash, stake);
    }


    function play(bytes32 gameHash, bytes32 playerMoveHash) public whenNotPaused {

        require(gameHash != bytes32(0), "Game hash cannot be empty");
        require(playerMoveHash != bytes32(0), "Move hash cannot be empty");

        Game storage game = games[gameHash];

        require(game.stake != 0, GAME_NOT_FOUND_MSG);
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        if (msg.sender == game.playerOne) {
            require(game.playerOneStaked, STAKE_NOT_RECEIVED_MSG);
            require(game.playerOneMoveHash == bytes32(0), MOVE_RECEIVED_MSG);
            game.playerOneMoveHash = playerMoveHash;
            return;
        } else {
            require(game.playerTwoStaked, STAKE_NOT_RECEIVED_MSG);
            require(game.playerTwoMoveHash == bytes32(0), MOVE_RECEIVED_MSG);
            game.playerTwoMoveHash = playerMoveHash;
        }

    }

    function revealPlayerMove(bytes32 gameHash, bytes32 secret, uint8 playerMove) external onlyOwner {
        Game storage game = games[gameHash];

        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        bytes32 expectedMoveHash = hashPlayerMove(msg.sender, secret, playerMove);

        if (msg.sender == game.playerOne) {
            require(game.playerOneMoveHash == expectedMoveHash, BAD_MATCH_MSG);
            game.playerOneMove = playerMove;
            if (game.playerTwoMove != 0) {
                emit GameCompleted(gameHash);
            }
        }

        if (msg.sender == game.playerTwo) {
            require(game.playerTwoMoveHash == expectedMoveHash, BAD_MATCH_MSG);
            game.playerTwoMove = playerMove;
            if (game.playerOneMove != 0) {
                emit GameCompleted(gameHash);
            }
        }
    }


    function rewardWinner(bytes32 gameHash) external onlyOwner whenNotPaused {
        Game storage game = games[gameHash];
        require(game.stake != 0, GAME_NOT_FOUND_MSG);

        address winner;

        if (isWinningMove(game.playerOneMove, game.playerTwoMove)) {
            winner = game.playerOne;
        } else {
            winner = game.playerTwo;
        }

        game.winner = winner;

        uint winnings = game.stake * 2;

        //Reset to reuse
        game.playerOneMove = 0;
        game.playerTwoMove = 0;
        game.playerOneStaked = false;
        game.playerTwoStaked = false;
        game.playerOneMoveHash = bytes(0);
        game.playerTwoMoveHash = bytes(0);

        emit WinnerRewarded(gameHash, winner, winnings);

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

    function withdraw(uint amount) public whenNotPaused returns(bool success) {
        uint256 withdrawerBalance = balances[msg.sender];
        require(amount > 0, "The value must be greater than 0");
        require(withdrawerBalance >= amount, "There are insufficient funds");

        balances[msg.sender] = SafeMath.sub(withdrawerBalance, amount);
        emit WithDraw(msg.sender, amount);
        (success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

//    function withdrawStake(bytes32 gameHash) whenNotPaused external whenNotPaused returns (bool success){
//        Game storage game = games[gameHash];
//        require(game.stake != 0, GAME_NOT_FOUND_MSG);
//        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);
//
//        if (msg.sender == game.playerOne) {
//            require(!game.playerTwoStaked, OPPONENT_ALREADY_STAKED_MSG);
//            require(game.playerOneStaked, NO_STAKE_TO_WITHDRAW_MSG);
//        }
//
//        if (msg.sender == game.playerTwo) {
//            require(!game.playerOneStaked, OPPONENT_ALREADY_STAKED_MSG);
//            require(game.playerTwoStaked, NO_STAKE_TO_WITHDRAW_MSG);
//        }
//
//        emit WithDrawStake(msg.sender, game.stake);
//
//        (success,) = msg.sender.call{value : game.stake}("");
//
//        return success;
//    }

    function createGameHash(address playerOne, address playerTwo) public view returns (bytes32){
        require(playerOne != NULL_ADDRESS, "1st address cannot be zero");
        require(playerTwo != NULL_ADDRESS, "2nd address cannot be zero");

        return keccak256(abi.encodePacked(playerOne, playerTwo, address(this)));
    }

    function hashPlayerMove(address player, bytes32 secret, uint playerMove) public view returns (bytes32) {
        require(secret != bytes32(0), "Secret cannot be empty");
        require(player != NULL_ADDRESS, "Address cannot be zero");

        return keccak256(abi.encodePacked(player, secret, playerMove, address(this)));
    }

    function getWinner(bytes32 gameHash) external view returns (address) {
        Game storage game = games[gameHash];
        require(game.stake != 0, GAME_NOT_FOUND_MSG);
        require(game.winner != address(0), "No winner yet");

        return game.winner;
    }

    function setStake(bytes32 gameHash, uint stake) external onlyOwner {

        require(stake > 0, "Stake must be greater than 0");

        Game storage game = games[gameHash];
        require(!game.playerOneStaked && !game.playerTwoStaked, "Game in progress");
        game.stake = stake;

        return game.winner;
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}