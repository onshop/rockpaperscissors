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
    string private constant ONLY_CREATOR_CALL_MSG = "Only creator can call";
    string private constant GAME_NOT_FOUND_MSG = "Game not found";
    string private constant INVALID_MOVE_MSG = "Invalid move";

    uint256 constant FORFEIT_WINDOW = 12 hours;
    uint256 constant FEE_PERCENTAGE = 10;

    struct Game {
        address creator;
        uint256 stake;
        bytes32 moveHash;
        address opponent;
        uint8 opponentMove;
        uint256 expiryDate;
    }

    event Deposit(
        address player,
        uint256 amount
    );

    event GameCreated(
        address indexed creator,
        bytes32 indexed gameToken,
        uint256 stake
    );

    event OpponentPlays(
        address indexed opponent,
        bytes32 indexed token,
        uint8 move
    );

    event Draw(
        bytes32 indexed token
    );

    event WinnerRewarded(
        bytes32 indexed gameToken,
        address indexed winner,
        address indexed loser,
        uint256 winnings,
        uint8 creatorMove,
        uint8 opponentMove
    );

    event WithDraw(
        address indexed withdrawer,
        uint amount
    );

    event  CreatorEndsGame(
        address indexed player,
        bytes32 indexed gameToken,
        uint256 refund
    );

    event  ForfeitPaid(
        address indexed player,
        bytes32 indexed gameToken,
        uint256 forfeit
    );

    function create(bytes32 playerMoveHash, uint stake) external payable whenNotPaused  returns(bytes32){

        require(playerMoveHash != bytes32(0), "Player move cannot be empty");
        require(stake > 0, "Stake cannot be zero");

        bytes32 gameToken = keccak256(abi.encodePacked(msg.sender, block.timestamp));

        Game storage game = games[gameToken];
        require(game.creator == NULL_ADDRESS, "Token already in use");

        game.creator = msg.sender;
        game.stake = stake;
        game.moveHash = playerMoveHash;
        fundMove(stake);
        emit GameCreated(msg.sender, gameToken, stake);

        return gameToken;
    }

    /*
    * The opponent makes their move and waits for the creator to resolve the game by revealing their move
    */
    function opponentPlay(bytes32 gameToken, uint8 playerMove) external payable whenNotPaused {

        Game storage game = games[gameToken];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        require(game.opponent == NULL_ADDRESS, "Opponent has already moved");
        require(playerMove < 3, INVALID_MOVE_MSG);

        game.opponentMove = playerMove;
        game.expiryDate =  block.timestamp + FORFEIT_WINDOW;
        fundMove(stake);
        emit OpponentPlays(msg.sender, gameToken, playerMove);
    }


    function fundMove(uint256 stake) internal {
        uint256 senderBalance = balances[msg.sender];

        if (msg.value < stake) {
            require(balances[msg.sender] >= stake - msg.value, "Insufficient balance");
            balances[msg.sender] = SafeMath.sub(senderBalance, stake - msg.value);
            return;
        }

        balances[msg.sender] = senderBalance.add(msg.value - stake);
        return;
    }

    /**
    * Once the opponent has made their move, the creator of the game must resolve to determine the winner
    * and reward the winner.
    * If the creator does not resolve the game then the opponent can collect their winnings
     * after the forfeit window has expired.
    */
    function resolveGame(bytes32 gameToken, bytes32 secret, uint8 creatorMove) external whenNotPaused {

        Game storage game = games[gameToken];

        address creator = game.creator;
        require(msg.sender == creator, ONLY_CREATOR_CALL_MSG);
        require(creatorMove < 3, INVALID_MOVE_MSG);

        address opponent = game.opponent;
        require(opponent != NULL_ADDRESS , "Still awaiting opponent");

        //Validate move
        bytes32 expectedMoveHash = hashPlayerMove(gameToken, secret, creatorMove);
        require(game.moveHash == expectedMoveHash, "Move and secret do not match");

        uint8 opponentMove = game.opponentMove;
        uint256 stake = game.stake;

        //Draw
        if(opponentMove == creatorMove){
            resetGame(game);
            emit Draw(gameToken);
            balances[creator] = balances[creator].add(stake);
            balances[opponent] = balances[opponent].add(stake);
            return;
        }

        //Determine winner
        address winner;
        address loser;
        uint256 winnings = stake * 2;
        uint256 fee = stake * FEE_PERCENTAGE/100;

        // If the creator wins then is rewarded by not paying a fee on the winnings
        if ((opponentMove + 1) % 3 == creatorMove) {
            winner = creator;
            loser = opponent;
            winnings = winnings + fee;
            balances[creator] = balances[creator].add(winnings);
        // If the creator loses then rewarded by being able to charge the opponent with a player's fee
        } else {
            winner = opponent;
            loser = creator;
            balances[opponent] = balances[opponent].add(winnings - fee);
            balances[creator] = balances[creator].add(fee); // Creator rewarded
        }

        resetGame(game);
        emit WinnerRewarded(gameToken, winner, loser, winnings, creatorMove, opponentMove);
    }

    function withdraw(uint amount) external whenNotPaused returns(bool success) {
        uint256 withdrawerBalance = balances[msg.sender];
        require(amount > 0, "The value must be greater than 0");
        require(withdrawerBalance >= amount, "There are insufficient funds");

        balances[msg.sender] = SafeMath.sub(withdrawerBalance, amount);
        emit WithDraw(msg.sender, amount);

        (success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    /*
    * If no opponent has played the game then the creator of the game can terminate the game
    * and collect their stake
    */
    function endGame(bytes32 gameToken) whenNotPaused external whenNotPaused {
        Game storage game = games[gameToken];

        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        address creator = game.creator;
        require(msg.sender == creator, ONLY_CREATOR_CALL_MSG);
        require(game.opponent == NULL_ADDRESS, "Opponent has played");

        // No opponent has yet played so refund
        resetGame(game);
        balances[creator] = balances[creator].add(stake);
        emit CreatorEndsGame(creator, gameToken, stake);
    }

    /*
    * If expiry has passed, the opponent forfeits their stake
    * They also pay no fee as a compensation
    * Creator punished by not getting a fee refunded that would have received if resolved
    */
    function collectForfeit(bytes32 gameToken) whenNotPaused external whenNotPaused {
        Game storage game = games[gameToken];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        address opponent = game.opponent;

        require(msg.sender == opponent, "Only opponent can call");

        require(block.timestamp >= game.expiryDate, "Awaiting game resolution");

        uint256 forfeit = stake * 2;
        resetGame(game);
        balances[opponent] = balances[opponent].add(forfeit);
        emit ForfeitPaid(opponent, gameToken, forfeit);
    }

    function resetGame(Game storage game) internal {
        game.stake = 0;
        game.moveHash = bytes32(0);
        game.opponentMove = 0;
        game.expiryDate = 0;
    }

    function hashPlayerMove(bytes32 gameToken, bytes32 secret, uint move) public view returns (bytes32) {
        require(gameToken != bytes32(0), "Game token cannot be empty");
        require(secret != bytes32(0), "Secret cannot be empty");
        require(move < 3, INVALID_MOVE_MSG);

        return keccak256(abi.encodePacked(gameToken, msg.sender, secret, move));
    }

    function pause() public onlyOwner {
        super._pause();
    }

    function unpause() public onlyOwner {
        super._unpause();
    }
}