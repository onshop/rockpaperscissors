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
    string private constant INVALID_PLAYER_MSG = "Invalid player";
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
        bytes32 indexed token,
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

    function deposit() external payable whenNotPaused {

        balances[msg.sender] = balances[msg.sender].add(msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    function create(bytes32 gameToken, bytes32 playerMoveHash, uint stake) external payable whenNotPaused  returns(bytes32){

        require(gameToken != bytes32(0), "Game token cannot be empty");
        require(stake > 0, "Stake cannot be zero");

        //Introduced some uniqueness in case the same token is reused
        bytes32 hashedGameToken = keccak256(abi.encodePacked(gameToken, block.timestamp));

        Game storage game = games[hashedGameToken];
        require(game.creator == NULL_ADDRESS, "Token already in use");

        emit GameCreated(msg.sender, hashedGameToken, stake);

        game.creator = msg.sender;
        game.stake = stake;
        game.moveHash = playerMoveHash;
        fundMove(stake);

        return hashedGameToken;
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

        emit OpponentPlays(msg.sender, gameToken, playerMove);

        game.opponent = msg.sender;
        game.opponentMove = playerMove;
        game.expiryDate =  block.timestamp + FORFEIT_WINDOW;
        fundMove(stake);
    }


    function fundMove(uint256 stake) internal {
        uint256 senderBalance = balances[msg.sender];
        uint256 fee = stake * 100/ FEE_PERCENTAGE;
        if (msg.value == 0){
            balances[msg.sender] = SafeMath.sub(senderBalance, stake + fee);
        } else if(msg.value > stake + fee){
            balances[msg.sender] = senderBalance.add(msg.value - stake + fee);
        } else {
            require(balances[msg.sender] >= stake + fee - msg.value, "Insufficient balance");
            balances[msg.sender] = SafeMath.sub(senderBalance, stake + fee - msg.value);
        }
    }

    /**
    * Once the opponent has made their move, the creator of the game must resolve to determine the winner
    * and reward the winner.
    * If the creator does not resolve the game then the opponent can collect their winnings
     * after the forfeit window has expired.
    */
    function resolveGame(bytes32 gameToken, bytes32 secret, uint8 creatorMove) external whenNotPaused {

        Game storage game = games[gameToken];

        require(msg.sender == game.creator, INVALID_PLAYER_MSG);
        require(creatorMove < 3, INVALID_MOVE_MSG);

        address opponent = game.opponent;
        require(opponent != NULL_ADDRESS , "Awaiting opponent");

        //Validate move
        bytes32 expectedMoveHash = hashPlayerMove(gameToken, secret, creatorMove);
        require(game.moveHash == expectedMoveHash, "Move and secret do not match");

        uint8 opponentMove = game.opponentMove;
        uint256 stake = game.stake;
        uint256 fee = stake * (FEE_PERCENTAGE /100);

        //Draw
        if(opponentMove == creatorMove){
            resetGame(game);
            emit Draw(gameToken);
            balances[msg.sender] = balances[msg.sender].add(stake + fee);
            balances[opponent] = balances[opponent].add(stake + fee);
            return;
        }

        //Determine winner
        address winner;
        address loser;
        uint256 winnings = (game.stake * 2);

        // Creator is rewarded for resolving by getting their fee back
        // Contract keeps the opponent's fee
        if ((opponentMove + 1) % 3 == creatorMove) { // Creator wins
            winner = game.creator;
            winnings = winnings + fee;
            balances[msg.sender] = balances[msg.sender].add(winnings + fee);
        } else { // Opponent wins
            winner = game.opponent;
            balances[opponent] = balances[opponent].add(winnings);
            balances[msg.sender] = balances[msg.sender].add(fee); // // Creator rewarded
        }

        //Reward winner
        resetGame(game);
        emit WinnerRewarded(gameToken, winner, loser, winnings, creatorMove, opponentMove);
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

    /*
    * If no opponent has played the game then the creator of the game can terminate the game
    * and collect their stake
    */
    function endGame(bytes32 gameToken) whenNotPaused external whenNotPaused {
        Game storage game = games[gameToken];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        address creator = game.creator;
        require(msg.sender == creator, INVALID_PLAYER_MSG);

        // No opponent has played so refund
        if(game.opponent == NULL_ADDRESS){
            resetGame(game);
            emit CreatorEndsGame(creator, gameToken, stake);
            balances[creator] = balances[creator].add(stake);
            return;
        }
        revert("Game unresolved");
    }

    /*
    * If expiry has passed, the opponent receives their stake and the forfeited stake
    * They also get their fee refunded as compensation
    * Creator's fee/deposit is kept by the contract
    */
    function collectForfeit(bytes32 gameToken) whenNotPaused external whenNotPaused {
        Game storage game = games[gameToken];
        uint256 stake = game.stake;
        require(stake != 0, GAME_NOT_FOUND_MSG);
        address opponent = game.opponent;

        require(msg.sender == opponent, INVALID_PLAYER_MSG);

        require(block.timestamp >= game.expiryDate, "Awaiting game resolution");

        uint forfeit = (stake * 2) + (stake * FEE_PERCENTAGE /100);
        emit ForfeitPaid(opponent, gameToken, forfeit);
        resetGame(game);
        balances[opponent] = balances[opponent].add(forfeit);
    }

    function resetGame(Game storage game) internal {
        game.stake = 0;
        game.moveHash = bytes32(0);
        game.opponentMove = 0;
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