//SPDX-License-Identifier: MIT
pragma solidity >= 0.6.0 < 0.7.0;

import "access/Ownable.sol";
import "utils/Pausable.sol";

contract RockPaperScissors is Ownable, Pausable {

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

    event WithDrawStake(
        address withdrawer,
        uint stake
    );

    uint8 constant ROCK = 1;
    uint8 constant PAPER = 2;
    uint8 constant SCISSORS = 3;


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


    function depositStake(bytes32 gameHash) public payable whenNotPaused {

        Game storage game = games[gameHash];

        require(game.stake != 0, GAME_NOT_FOUND_MSG);
        require(msg.value == game.stake, "Deposit does not match stake");
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        if (game.playerOne == msg.sender) {
            game.playerOneStaked = true;
        } else if (game.playerTwo == msg.sender) {
            game.playerTwoStaked = true;
        }

        emit DepositStake(msg.sender, gameHash, msg.value);
    }


    function move(bytes32 gameHash, bytes32 playerMoveHash) public whenNotPaused {

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
        }

        if (msg.sender == game.playerTwo) {
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


    function rewardWinner(bytes32 gameHash) external onlyOwner whenNotPaused returns (bool success){
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
        game.stake = 0;
        game.playerOneMove = 0;
        game.playerTwoMove = 0;

        emit WinnerRewarded(gameHash, winner, winnings);

        (success,) = winner.call{value : winnings}("");

        require(success, "Transfer failed");
    }

    function getWinner(bytes32 gameHash) external view returns (address) {
        Game storage game = games[gameHash];
        require(game.stake != 0, GAME_NOT_FOUND_MSG);
        require(game.winner != address(0), "No winner yet");

        return game.winner;
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

    function withdrawStake(bytes32 gameHash) whenNotPaused external whenNotPaused returns (bool success){
        Game storage game = games[gameHash];
        require(game.stake != 0, GAME_NOT_FOUND_MSG);
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, INVALID_PLAYER_MSG);

        if (msg.sender == game.playerOne) {
            require(!game.playerTwoStaked, OPPONENT_ALREADY_STAKED_MSG);
            require(game.playerOneStaked, NO_STAKE_TO_WITHDRAW_MSG);
        }

        if (msg.sender == game.playerTwo) {
            require(!game.playerOneStaked, OPPONENT_ALREADY_STAKED_MSG);
            require(game.playerTwoStaked, NO_STAKE_TO_WITHDRAW_MSG);
        }

        emit WithDrawStake(msg.sender, game.stake);

        (success,) = msg.sender.call{value : game.stake}("");

        return success;
    }

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

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}