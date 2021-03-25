## Rock Paper Scissors

Ethereum contract to enable two players to play the classic rock paper scissors game.

User journey/sequence is as follows:

1. A player (creator) initialises the game. The contract generates a game token that is returned for use in subsequent 
   calls and this cannot be reused for new games. The player can send value to fund it at the same time or from their 
   existing balance.
2. Another player (opponent) plays the game. An expiry date on the contract is set for the creator to reveal and avoid a forfeit.
3. The creator must then reveal to determine the winner and then winner's balance is funded with the winnings.
   The creator is incentivised to reveal, even if they have lost, by also being rewarded with the fee charged to the opponent.
   This also compensates the game creator for the gas costs of managing the game.
   If the creator does no reveal, they not only lose their stake but also the fee (10%) charged to the opponent.
4. If the creator fails to reveal, after the expiry date then the opponent can claim back their stake and the creator's stake
   As compensation for delayed payment and inconvenience, they do not pay any fee for playing.
   
### Thoughts

1. If I was setting a minimum stake (so that the fee covers gas, would that be determined on the front end?)
2. I was considering that perhaps the contract owner should be able to flexibly set a minimum stake and the fee percentage
with setter functions.