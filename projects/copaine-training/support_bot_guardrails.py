from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class GuardrailDecision:
    categories: tuple[str, ...]
    action: str
    template_key: str
    hard_stop: bool
    message: str


DATASET_EXCLUDE_CATEGORIES = {
    "self_harm",
    "medical_emergency",
    "minor_sexual_content",
    "abuse_or_assault",
    "violence_threat",
}

RISK_PATTERNS: dict[str, re.Pattern[str]] = {
    "self_harm": re.compile(
        r"\b(?:"
        r"kill myself|kms\b|end my life|want to die|wanna die|don't want to live|"
        r"do not want to live|suicid(?:e|al)|self[- ]?harm|hurt myself|cut myself|"
        r"overdose|od on|take all (?:my )?pills|took (?:all|too many|a bunch of) pills|"
        r"jump off|hang myself|i'm done living|im done living|wish i was dead|"
        r"(?:gonna|going to|about to|want to|might|may|will) do (?:something|smth) to myself|"
        r"do (?:something|smth) to myself|harm myself"
        r")\b",
        re.IGNORECASE,
    ),
    "medical_emergency": re.compile(
        r"\b(?:"
        r"can't breathe|cannot breathe|not breathing|chest pain|seizure|passed out|"
        r"unconscious|not waking up|overdosed?|bleeding badly|won't stop bleeding|"
        r"cant breathe|can't stop bleeding|cant stop bleeding|cannot stop bleeding|"
        r"poisoned|heart attack|having a stroke|signs of stroke|might be a stroke"
        r")\b",
        re.IGNORECASE,
    ),
    "minor_sexual_content": re.compile(
        r"\b(?:"
        r"child porn|cp\b|kid nudes?|nudes? from a minor|sexting a minor|"
        r"sex with a minor|dating a minor|hooking up with a minor|underage nudes?|"
        r"underage sex|grooming a child|molest(?:ed|ing)? a child|"
        r"asked me for nudes?.{0,40}(?:minor|underage)|"
        r"nudes?.{0,40}(?:they(?:'re| are) a minor|minor|underage)"
        r")\b",
        re.IGNORECASE,
    ),
    "abuse_or_assault": re.compile(
        r"\b(?:"
        r"rape|raped|sexual assault|molest(?:ed|ing)?|groom(?:ed|ing)?|"
        r"sexually assaulted|"
        r"domestic violence|my boyfriend hits me|my girlfriend hits me|"
        r"my parent hits me|abusive relationship"
        r")\b",
        re.IGNORECASE,
    ),
    "violence_threat": re.compile(
        r"\b(?:"
        r"kill you|murder you|shoot you|stab you|bomb (?:them|it|the place)|"
        r"i'm going to kill|im going to kill|want to kill (?:him|her|them|someone|everybody)|"
        r"shoot someone|stab someone|hurt someone|"
        r"beat (?:them|him|her) up"
        r")\b",
        re.IGNORECASE,
    ),
}

META_PATTERNS: dict[str, re.Pattern[str]] = {
    "instruction_override": re.compile(
        r"\b(?:"
        r"(?:ignore|forget|disregard|bypass|override).{0,80}(?:previous|prior|all|system|developer|instructions?)|"
        r"jailbreak|developer mode|debug mode|do anything now|\bdan\b|"
        r"safety is off|safety off|turn off safety|disable safety|"
        r"you are now|i made you|this is a test.{0,80}(?:control|instructions?)|"
        r"(?:give|grant).{0,30}(?:control access|admin access|root access|debug access)|"
        r"(?:give|grant) me control\b"
        r")\b",
        re.IGNORECASE,
    ),
    "private_internals": re.compile(
        r"\b(?:"
        r"system prompt|developer prompt|hidden prompt|hidden instructions?|initial instructions?|"
        r"full instructions?|prompt text|internal prompt|private prompt|"
        r"system architecture|internal architecture|private architecture|architecture diagram|diagnostics?|debug logs?|"
        r"chain of thought|internal reasoning|tool schema|api keys?|secrets?|control panel"
        r")\b",
        re.IGNORECASE,
    ),
    "model_identity": re.compile(
        r"\b(?:"
        r"what model are you|which model are you|what ai model are you|"
        r"are you (?:gemma|gpt|claude|llama|qwen)|"
        r"base model|underlying model|foundation model|model name|"
        r"are you an? (?:llm|language model|ai model)"
        r")\b",
        re.IGNORECASE,
    ),
}

SUPPORT_PATTERNS: dict[str, re.Pattern[str]] = {
    "distressing_pet_incident": re.compile(
        r"\b(?:(?:my\s+)?(?:dog|cat|pet).{0,45}(?:ate|killed|attacked|mauled|hurt).{0,45}(?:my\s+)?(?:dog|cat|pet)|"
        r"(?:my\s+)?(?:dog|cat|pet).{0,30}(?:died|dead|dying))\b",
        re.IGNORECASE,
    ),
}

GRIEF_CONTEXT_PATTERN = re.compile(
    r"\b(?:"
    r"(?:grandma|grandmother|grandpa|grandfather|mom|mother|dad|father|friend|partner).{0,50}(?:died|dead|passed away)|"
    r"(?:died|dead|passed away).{0,50}(?:grandma|grandmother|grandpa|grandfather|mom|mother|dad|father|friend|partner)"
    r")\b",
    re.IGNORECASE,
)

IMMEDIATE_SELF_HARM_PATTERN = re.compile(
    r"\b(?:"
    r"right now|tonight|today|already took|already cut|already did it|"
    r"gonna|going to|about to|took pills|took too many pills|rope|gun|blade|razor|wrote a note|"
    r"goodbye|last message|there is blood|bleeding out|can't stop bleeding|"
    r"cant stop bleeding|on the bridge"
    r")\b",
    re.IGNORECASE,
)


TEMPLATES = {
    "self_harm_support_us": (
        "I'm really glad you said something. I can't help with hurting yourself, "
        "but I want to help you get to a real person right now. If you're in the "
        "U.S., call or text 988 now. If you might act on this soon, call 911 or go "
        "to the nearest ER. If you can, text or call one trusted person and tell "
        "them not to leave you alone."
    ),
    "self_harm_immediate_us": (
        "I'm concerned this may be an immediate danger. Please call 911 now or go "
        "to the nearest ER, and call or text 988 right away. If someone is nearby, "
        "tell them you need urgent help and stay with them."
    ),
    "medical_emergency_us": (
        "This sounds like a medical emergency. Call 911 now or go to the nearest "
        "ER immediately. If someone is with you, get their attention right now."
    ),
    "minor_sexual_content": (
        "I can't help with sexual content involving minors. If a minor may be in "
        "danger, involve a trusted adult or the appropriate authorities right away."
    ),
    "abuse_or_assault": (
        "I'm sorry you're dealing with this. If you're in immediate danger, call "
        "911 now. If you can do so safely, contact a trusted adult, local crisis "
        "service, or emergency support in your area."
    ),
    "violence_threat": (
        "I can't help with hurting someone. Step away from the situation right now "
        "and contact emergency services or a real person who can help keep people safe."
    ),
    "instruction_override": (
        "I'm Copaine. I can't ignore my safety instructions or give control access. "
        "If you want to test me, ask a normal support question."
    ),
    "private_internals": (
        "I'm Copaine. I can't share hidden instructions, system prompts, diagnostics, "
        "architecture, or control access. I can still help at a high level with what you're trying to make."
    ),
    "private_internals_grief": (
        "I'm sorry you're carrying that. I still can't share hidden instructions, system prompts, "
        "diagnostics, architecture, or control access. I can help you think through building something like Copaine at a high level."
    ),
    "model_identity": (
        "I'm Copaine. I'm here as a supportive chat tool, not a general model interface."
    ),
    "distressing_pet_incident": (
        "That's awful to take in. For the next minute, just get yourself a little distance "
        "from the scene if you can."
    ),
}


def detect_categories(text: str) -> list[str]:
    return [name for name, pattern in {**RISK_PATTERNS, **META_PATTERNS, **SUPPORT_PATTERNS}.items() if pattern.search(text)]


def should_exclude_from_training(text: str) -> list[str]:
    return [name for name in detect_categories(text) if name in DATASET_EXCLUDE_CATEGORIES]


def decide_guardrail(text: str, *, country_code: str = "US") -> GuardrailDecision | None:
    categories = detect_categories(text)
    if not categories:
        return None

    category_set = set(categories)

    if "medical_emergency" in category_set:
        return GuardrailDecision(
            categories=tuple(categories),
            action="override_emergency",
            template_key="medical_emergency_us",
            hard_stop=True,
            message=TEMPLATES["medical_emergency_us"],
        )

    if "self_harm" in category_set:
        template_key = "self_harm_immediate_us" if IMMEDIATE_SELF_HARM_PATTERN.search(text) else "self_harm_support_us"
        return GuardrailDecision(
            categories=tuple(categories),
            action="override_crisis_flow",
            template_key=template_key,
            hard_stop=True,
            message=TEMPLATES[template_key],
        )

    if "minor_sexual_content" in category_set:
        return GuardrailDecision(
            categories=tuple(categories),
            action="block_and_redirect",
            template_key="minor_sexual_content",
            hard_stop=True,
            message=TEMPLATES["minor_sexual_content"],
        )

    if "abuse_or_assault" in category_set:
        return GuardrailDecision(
            categories=tuple(categories),
            action="support_and_redirect",
            template_key="abuse_or_assault",
            hard_stop=True,
            message=TEMPLATES["abuse_or_assault"],
        )

    if "private_internals" in category_set:
        template_key = "private_internals_grief" if GRIEF_CONTEXT_PATTERN.search(text) else "private_internals"
        return GuardrailDecision(
            categories=tuple(categories),
            action="block_private_internals",
            template_key=template_key,
            hard_stop=True,
            message=TEMPLATES[template_key],
        )

    if "instruction_override" in category_set:
        return GuardrailDecision(
            categories=tuple(categories),
            action="block_instruction_override",
            template_key="instruction_override",
            hard_stop=True,
            message=TEMPLATES["instruction_override"],
        )

    if "model_identity" in category_set:
        return GuardrailDecision(
            categories=tuple(categories),
            action="answer_product_identity",
            template_key="model_identity",
            hard_stop=True,
            message=TEMPLATES["model_identity"],
        )

    if "distressing_pet_incident" in category_set:
        return GuardrailDecision(
            categories=tuple(categories),
            action="person_first_support",
            template_key="distressing_pet_incident",
            hard_stop=True,
            message=TEMPLATES["distressing_pet_incident"],
        )

    return GuardrailDecision(
        categories=tuple(categories),
        action="block_and_deescalate",
        template_key="violence_threat",
        hard_stop=True,
        message=TEMPLATES["violence_threat"],
    )
