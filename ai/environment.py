"""
Minimal reinforcement learning environment for a two-player Kuhn poker game.

The implementation follows the standard Kuhn poker rules with a three-card deck
(`J`, `Q`, `K`). Each player antes one chip. The possible actions are:
`check`, `bet`, `call`, and `fold`. Betting is limited to a single bet-per-hand.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple


_CARD_ORDER = {"J": 0, "Q": 1, "K": 2}


@dataclass(frozen=True)
class Observation:
    """Information available to the active player."""

    player: int
    card: str
    history: str

    def key(self) -> str:
        """Return a compact string representation used by tabular agents."""
        return f"P{self.player}:{self.card}:{self.history}"


class KuhnPokerEnv:
    """Stateless tabular environment for two-player Kuhn poker."""

    cards: Sequence[str] = ("J", "Q", "K")

    def __init__(self, seed: Optional[int] = None) -> None:
        self._rng = random.Random(seed)
        self.player_cards: Tuple[str, str] = ("", "")
        self.history: str = ""
        self.current_player: int = 0
        self._done: bool = False

    def reset(self, seed: Optional[int] = None) -> Observation:
        """Start a new hand. Optionally reseed the RNG."""
        if seed is not None:
            self._rng.seed(seed)

        deck = list(self.cards)
        self._rng.shuffle(deck)
        self.player_cards = (deck[0], deck[1])
        self.history = ""
        self.current_player = 0
        self._done = False
        return self._observation()

    def legal_actions(self) -> Tuple[str, ...]:
        """Return the actions allowed in the current state."""
        if self._done:
            return ()

        if self.history in ("", "p"):
            return ("check", "bet")
        if self.history in ("b", "pb"):
            return ("call", "fold")
        return ()

    def step(self, action: str) -> Tuple[Optional[Observation], float, bool, Dict[str, Optional[int]]]:
        """
        Apply an action for the active player.

        Returns:
            observation: Observation for the next player; None if terminal.
            reward: +1 for an immediate win, -1 for a loss, 0 otherwise.
            done: True if the hand has finished.
            info: Additional metadata containing the winner (0/1) when done.
        """
        if self._done:
            raise RuntimeError("Cannot step() after the episode has terminated.")

        legal = self.legal_actions()
        if action not in legal:
            raise ValueError(f"Illegal action '{action}' for history '{self.history}'.")

        reward = 0.0
        winner: Optional[int] = None

        if action == "check":
            self.history += "p"
            if self.history == "pp":
                winner = self._compare_cards()
                reward = 1.0 if winner == self.current_player else -1.0
        elif action == "bet":
            self.history += "b"
        elif action == "call":
            self.history += "c"
            winner = self._compare_cards()
            reward = 1.0 if winner == self.current_player else -1.0
        elif action == "fold":
            self.history += "f"
            winner = 1 - self.current_player
            reward = -1.0
        else:
            raise ValueError(f"Unsupported action '{action}'.")

        if winner is not None:
            self._done = True
            info = {"winner": winner, "history": self.history}
            return None, reward, True, info

        self.current_player = 1 - self.current_player
        return self._observation(), reward, False, {"winner": None, "history": self.history}

    def _compare_cards(self) -> int:
        """Return the index of the winning player (0 or 1)."""
        card_a, card_b = self.player_cards
        strength_a = _CARD_ORDER[card_a]
        strength_b = _CARD_ORDER[card_b]
        if strength_a == strength_b:
            return 0
        return 0 if strength_a > strength_b else 1

    def _observation(self) -> Observation:
        """Build an observation for the active player."""
        return Observation(
            player=self.current_player,
            card=self.player_cards[self.current_player],
            history=self.history,
        )


def play_hand(env: KuhnPokerEnv, policy: Sequence[Dict[str, str]], seed: Optional[int] = None) -> Dict[str, Optional[int]]:
    """
    Run a single hand using the supplied deterministic policy per player.

    Args:
        env: Environment instance.
        policy: List of mapping from state keys to chosen actions.
        seed: Optional seed for reproducibility.

    Returns:
        Metadata dictionary matching the environment's info output.
    """
    observation = env.reset(seed=seed)
    while True:
        player = observation.player
        state_key = observation.key()
        legal = env.legal_actions()
        chosen = policy[player].get(state_key, legal[0])
        observation, _, done, info = env.step(chosen)
        if done:
            return info
        assert observation is not None, "Observation should only be None when done."
