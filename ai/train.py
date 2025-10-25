"""
Self-play training script for the tabular Kuhn poker agent.

Usage:
    python3 -m ai.train --episodes 50000
"""

from __future__ import annotations

import argparse
from typing import List, Sequence, Tuple

from ai.agent import TabularAgent
from ai.environment import KuhnPokerEnv, play_hand


def run_episode(env: KuhnPokerEnv, agents: Sequence[TabularAgent]) -> int:
    """Play one self-play episode and update agents in-place. Returns winner id."""
    trajectories = {0: [], 1: []}
    observation = env.reset()

    while True:
        player = observation.player
        state_key = observation.key()
        legal_actions = env.legal_actions()
        action = agents[player].select_action(state_key, legal_actions)
        trajectories[player].append((state_key, action))

        observation, _, done, info = env.step(action)
        if done:
            winner = info.get("winner")
            if winner is None:
                raise RuntimeError("Episode finished without a recorded winner.")

            for pid in (0, 1):
                final_reward = 1.0 if pid == winner else -1.0
                for state_key, taken_action in trajectories[pid]:
                    agents[pid].update(state_key, taken_action, final_reward)
            return winner

        if observation is None:
            raise RuntimeError("Received None observation before the episode finished.")


def train_self_play(
    episodes: int,
    epsilon: float,
    epsilon_decay: float,
    minimum_epsilon: float,
    report_every: int,
    seed: int | None = None,
) -> Tuple[List[TabularAgent], Tuple[int, int]]:
    """Train a pair of agents using self-play Monte Carlo updates."""
    env = KuhnPokerEnv(seed=seed)
    agents = [TabularAgent(epsilon=epsilon), TabularAgent(epsilon=epsilon)]
    wins = [0, 0]

    for episode in range(1, episodes + 1):
        winner = run_episode(env, agents)
        wins[winner] += 1

        for agent in agents:
            agent.epsilon = max(minimum_epsilon, agent.epsilon * epsilon_decay)

        if report_every and episode % report_every == 0:
            total = wins[0] + wins[1]
            pct = (wins[0] / total) * 100 if total else 0.0
            print(
                f"Episode {episode:6d} | P0 wins: {wins[0]} ({pct:5.2f}%) | "
                f"P1 wins: {wins[1]}"
            )

    return agents, (wins[0], wins[1])


def main() -> None:
    parser = argparse.ArgumentParser(description="Train a minimal Kuhn poker RL agent.")
    parser.add_argument("--episodes", type=int, default=50000, help="Training episodes.")
    parser.add_argument("--epsilon", type=float, default=0.2, help="Initial exploration rate.")
    parser.add_argument(
        "--epsilon-decay",
        type=float,
        default=0.999,
        help="Multiplicative decay applied after each episode.",
    )
    parser.add_argument(
        "--minimum-epsilon",
        type=float,
        default=0.01,
        help="Lower bound for epsilon.",
    )
    parser.add_argument(
        "--report-every",
        type=int,
        default=5000,
        help="Progress report interval. Set to 0 to disable logging.",
    )
    parser.add_argument("--seed", type=int, default=None, help="Optional RNG seed.")
    args = parser.parse_args()

    agents, wins = train_self_play(
        episodes=args.episodes,
        epsilon=args.epsilon,
        epsilon_decay=args.epsilon_decay,
        minimum_epsilon=args.minimum_epsilon,
        report_every=args.report_every,
        seed=args.seed,
    )

    print("\nTraining complete.")
    print(f"Final win counts -> Player 0: {wins[0]}, Player 1: {wins[1]}")

    greedy_policies = [agent.greedy_policy() for agent in agents]
    env = KuhnPokerEnv(seed=args.seed)
    info = play_hand(env, greedy_policies, seed=args.seed)
    print(f"Sample greedy hand winner: Player {info.get('winner')} (history: {info.get('history')})")


if __name__ == "__main__":
    main()
