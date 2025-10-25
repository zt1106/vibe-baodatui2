"""
Utilities to evaluate trained policies against a random opponent.

Run directly to print win rates:

    python3 -m ai.evaluation --games 100
"""

from __future__ import annotations

import argparse
import random
from typing import Dict

from ai.environment import KuhnPokerEnv
from ai.train import train_self_play


def evaluate_policy_against_random(
    policy: Dict[str, str],
    seat: int,
    games: int,
    base_seed: int,
) -> float:
    """
    Estimate the win rate of a deterministic policy against a random opponent.

    Args:
        policy: Mapping from observation keys to chosen actions.
        seat: Player index (0 or 1) controlled by the policy.
        games: Number of hands to evaluate.
        base_seed: Seed to keep environment and random opponent deterministic.

    Returns:
        Fraction of games won by the policy-controlled seat.
    """
    env = KuhnPokerEnv(seed=base_seed)
    opponent_rng = random.Random(base_seed + seat)
    wins = 0

    for _ in range(games):
        observation = env.reset()
        while True:
            player = observation.player
            legal_actions = env.legal_actions()

            if player == seat:
                action = policy.get(observation.key(), legal_actions[0])
            else:
                action = opponent_rng.choice(legal_actions)

            observation, _, done, info = env.step(action)

            if done:
                if info.get("winner") == seat:
                    wins += 1
                break

            if observation is None:
                raise RuntimeError("Observation unexpectedly None before termination.")

    return wins / games


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate trained policies against random opponents.")
    parser.add_argument("--episodes", type=int, default=50_000, help="Training episodes before evaluation.")
    parser.add_argument("--games", type=int, default=100, help="Evaluation games per seat.")
    parser.add_argument("--seed", type=int, default=42, help="RNG seed shared across training and evaluation.")
    args = parser.parse_args()

    random.seed(args.seed)
    agents, _ = train_self_play(
        episodes=args.episodes,
        epsilon=0.2,
        epsilon_decay=0.999,
        minimum_epsilon=0.01,
        report_every=0,
        seed=args.seed,
    )

    policies = [agent.greedy_policy() for agent in agents]

    seat0_rate = evaluate_policy_against_random(policies[0], seat=0, games=args.games, base_seed=args.seed * 3)
    seat1_rate = evaluate_policy_against_random(policies[1], seat=1, games=args.games, base_seed=args.seed * 5)

    print(f"Evaluated {args.games} games per seat after {args.episodes} training episodes (seed={args.seed}).")
    print(f"Seat 0 win rate vs random: {seat0_rate:.2%}")
    print(f"Seat 1 win rate vs random: {seat1_rate:.2%}")
    print(f"Average win rate: {(seat0_rate + seat1_rate) / 2:.2%}")


if __name__ == "__main__":
    main()
