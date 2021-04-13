## Rock Paper Scissors

Ethereum contract to enable two players to play the classic rock paper scissors game.

User journey/sequence is as follows:

1. Player one initialises the game. They send a payment and move hash created from a secret and the move. The move hash 
   is used as the game's key so the same secret cannot be reused for new games. The player can send value to fund it at
   the same time or from their existing balance.
2. Player two joins the game with a payment and sends their own move hash. An expiry date on the contract is set for 
   both parties to reveal and avoid a forfeit.
3. Player one then reveals their move. The expiry date is again reset.
4. Player two reveals their move and then and the winner gets their stake back and the loser's stake.
5. If either player fails to reveal before the expiry date then either player can claim their stake and their
   opponent's forfeited stake.
6. Player one can end the game if no other player joins and refund their stake.
   