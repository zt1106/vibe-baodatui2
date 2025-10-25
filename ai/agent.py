"""
Tabular reinforcement learning agent for Kuhn poker self-play.

The agent keeps visit counts and average returns per (state, action) pair.
"""

from __future__ import annotations

import random
from collections import defaultdict
from typing import DefaultDict, Dict, Iterable, Tuple


class TabularAgent:
    """Monte Carlo tabular agent with epsilon-greedy exploration."""

    def __init__(self, epsilon: float = 0.1) -> None:
        self.epsilon = epsilon
        self._values: DefaultDict[str, Dict[str, float]] = defaultdict(dict)
        self._counts: DefaultDict[str, Dict[str, int]] = defaultdict(dict)

    def select_action(self, state_key: str, legal_actions: Iterable[str]) -> str:
        """Choose an action using the current policy and epsilon-greedy exploration."""
        legal = tuple(legal_actions)
        if not legal:
            raise ValueError("No legal actions available.")

        if random.random() < self.epsilon:
            return random.choice(legal)

        values = self._values[state_key]
        best_action = legal[0]
        best_value = values.get(best_action, 0.0)
        for action in legal[1:]:
            action_value = values.get(action, 0.0)
            if action_value > best_value:
                best_value = action_value
                best_action = action
        return best_action

    def update(self, state_key: str, action: str, reward: float) -> None:
        """Update the value estimates with the observed reward."""
        counts = self._counts[state_key]
        values = self._values[state_key]
        visits = counts.get(action, 0) + 1
        counts[action] = visits

        previous = values.get(action, 0.0)
        updated = previous + (reward - previous) / visits
        values[action] = updated

    def greedy_policy(self) -> Dict[str, str]:
        """Return the greedy policy derived from the current value estimates."""
        policy: Dict[str, str] = {}
        for state_key, action_values in self._values.items():
            if not action_values:
                continue
            best_action, _ = max(action_values.items(), key=lambda item: item[1])
            policy[state_key] = best_action
        return policy

    def value_table(self) -> Dict[str, Dict[str, float]]:
        """Return a deep copy of the current value table."""
        return {
            state: dict(actions)
            for state, actions in self._values.items()
        }
