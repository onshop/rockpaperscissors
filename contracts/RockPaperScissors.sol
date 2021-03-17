//SPDX-License-Identifier: MIT
pragma solidity >= 0.6.0 < 0.7.0;

import "access/Ownable.sol";
import "utils/Pausable.sol";

contract RockPaperScissors is Ownable, Pausable {

    mapping(bytes32 => Game) public games;

    struct Game {
        address playerOne;
        address playerTwo;
        uint256 stake;
        bool playerOneStaked;
        bool playerTwoStaked;
        string playerOneMove;
        string playerTwoMove;
    }

    event GameCreated(
        bytes32 indexed hash,
        uint256 amount
    );

    event DepositStake(
        address indexed player,
        bytes32 indexed hash,
        uint256 amount
    );

    event PlayerMove(
        address indexed player,
        bytes32 indexed hash,
        string playerMove
    );

    event GameResult(
        bytes32 indexed hash,
        address indexed winner
    );

    event WithDrawStake(
        address withdrawer,
        uint stake
    );

    string constant ROCK = 'R';
    string constant PAPER = 'P';
    string constant SCISSORS = 'S';

    function depositStake(bytes32 gameHash) public payable {

        Game storage game = games[gameHash];

        require(game.stake != 0, "Game not found");
        require(msg.value == game.stake, "Deposit does not match stake");
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, "Invalid player");

        if(game.playerOne == msg.sender) {
            game.playerOneStaked = true;
        } else if(game.playerTwo == msg.sender) {
            game.playerTwoStaked = true;
        }

        emit DepositStake(msg.sender, gameHash, msg.value);
    }

    function initialise(bytes32 gameHash, address playerOne, address playerTwo, uint stake) whenNotPaused {

        require(playerOne != msg.sender, "Caller cannot be player one");
        require(playerTwo != msg.sender, "Caller cannot be player two");
        require(playerOne != address(0), "Player one cannot be empty");
        require(playerTwo != address(0), "Player two cannot be empty");

        Game storage game = games[gameHash];

        game.playerOne = playerOne;
        game.playerTwo = playerTwo;
        game.stake = stake;

        emit GameCreated(gameHash, msg.value, playerOne, playerTwo, stake);
    }

    function move(bytes32 gameHash, string memory playerMove) whenNotPaused public returns(bool success){

        require(playerMove == ROCK || playerMove == PAPER || playerMove == SCISSORS, "Invalid move");

        Game storage game = games[gameHash];

        require(game.stake != 0, "Game not found");
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, "Invalid player");

        address memory adversary;
        string memory adversaryMove;

        if (msg.sender == game.playerOne) {
            require(game.playerOneStaked, "Stake payment not received");
            require(bytes(game.playerOneMove).length == 0, "Move already received");
            if (!game.playerTwoMove) {
                game.playerOneMove = playerMove;
                return;
            }
            adversary = game.playerTwo;
            adversaryMove = game.playerTwoMove;
        }

        if (msg.sender == game.playerTwo) {
            require(game.playerTwoStaked, "Stake payment not received");
            require(bytes(game.playerTwoMove).length == 0, "Move already received");
            if (bytes(game.playerTwoMove) == 0) {
                game.playerOneMove = playerMove;
                return;
            }
            adversary = game.playerOne;
            adversaryMove = game.playerOneMove;
        }

        uint winnings = game.stake * 2;
        game.stake = 0;
        game.playerOneMove = "";
        game.playerTwoMove = "";

        if (isWinningMove(playerMove, adversaryMove)) {
            (success, ) = msg.sender.call{value: winnings}("");
        } else {
            (success, ) = adversary.call{value: winnings}("");
        }

        require(success, "Transfer failed");
    }

    function isWinningMove(bytes32 memory playerMove, bytes32 memory adversaryMove) internal pure returns(bool) {

        if (playerMove == ROCK && adversaryMove == SCISSORS) {
            return true;
        }
        if (playerMove == PAPER && adversaryMove == ROCK) {
            return true;
        }
        if (playerMove == SCISSORS && adversaryMove == PAPER) {
            return true;
        }

        return false;
    }

    function createGameHash(address playerOne, address playerTwo) public view returns(bytes32){
        require(playerOne != NULL_ADDRESS, "1st address cannot be zero");
        require(playerTwo != NULL_ADDRESS, "2nd address cannot be zero");

        return keccak256(abi.encodePacked(playerOne, playerTwo, address(this)));
    }

    function withdrawStake(bytes32 gameHash) whenNotPaused external returns(bool success){
        Game storage game = games[gameHash];
        require(game.stake != 0, "Game not found");
        require(msg.sender == game.playerOne || msg.sender == game.playerTwo, "Invalid player");

        if (msg.sender == game.playerOne) {
            require(!game.playTwoStaked, "Adversary has already staked");
            require(game.playOneStaked, "No stake to withdraw");
        }

        if (msg.sender == game.playerTwo) {
            require(!game.playOneStaked, "Adversary has already staked");
            require(game.playTwoStaked, "No stake to withdraw");
        }

        emit WithDraw();

        (success, ) = msg.sender.call{value: game.stake}("");

        return success;
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}