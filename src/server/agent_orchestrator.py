"""Agent Orchestrator — routes requests to AG-UI Strands agent wrappers.

Creates ``ag_ui_strands.StrandsAgent`` wrappers per-request so that
per-request HTTP headers (e.g. Authorization) can be forwarded to the
MCP server.  The outer shell (routing, auth, persistence, SSE encoding,
cancellation) remains custom; this module is the thin glue between the
router and the off-the-shelf AG-UI event conversion layer.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator, Callable
from typing import Any

from ag_ui.core import RunAgentInput
from ag_ui_strands import StrandsAgent as AGUIStrandsAgent
from ag_ui_strands.config import StrandsAgentConfig
from strands import Agent as StrandsAgentCore

from orchestrator.router import PageContextRouter
from utils.logging_helpers import get_logger, log_debug_event, log_info_event

logger = get_logger(__name__)

# A factory callable that receives optional HTTP headers and returns a
# pre-configured Strands Agent.
AgentFactory = Callable[[dict[str, str] | None], StrandsAgentCore]


def _extract_app_id_from_context(context: list) -> str | None:
    """Extract appId from the AG-UI context array.

    OpenSearch Dashboards sends page context as a Context entry with a JSON
    value containing ``appId`` (e.g. "discover", "explore", "home").
    This function finds the first entry whose value contains an appId.

    Args:
        context: List of AG-UI Context objects (description + value).

    Returns:
        The appId string, or None if not found.
    """
    for ctx in context:
        try:
            value = ctx.value if isinstance(ctx.value, dict) else json.loads(ctx.value)
            if isinstance(value, dict) and "appId" in value:
                app_id = value["appId"]
                log_debug_event(
                    logger,
                    f"Extracted appId='{app_id}' from AG-UI context",
                    "orchestrator.context_app_id",
                    app_id=app_id,
                )
                return app_id
        except (json.JSONDecodeError, TypeError, AttributeError):
            continue
    return None


def _extract_page_context(input_data: RunAgentInput) -> str | None:
    """Extract page_context from RunAgentInput.

    Strategy:
      1. Check forwardedProps.page_context (direct override, useful for curl testing)
      2. Check AG-UI context array for page context with appId (sent by Dashboard)

    Args:
        input_data: AG-UI RunAgentInput.

    Returns:
        page_context string or None.
    """
    page_context = None
    if hasattr(input_data, "forwarded_props") and input_data.forwarded_props:
        page_context = input_data.forwarded_props.get("page_context")

    if not page_context and hasattr(input_data, "context") and input_data.context:
        page_context = _extract_app_id_from_context(input_data.context)

    return page_context


class AgentOrchestrator:
    """Routes AG-UI requests to the appropriate ``ag_ui_strands.StrandsAgent``.

    Instead of holding pre-created agents, the orchestrator stores *factory*
    functions.  Each factory receives optional HTTP headers and returns a
    fresh ``StrandsAgentCore``.  This allows per-request credentials
    (e.g. ``Authorization``) to be forwarded to the MCP server.

    ``run()`` resolves the agent name via :class:`PageContextRouter`,
    creates an agent from the factory, wraps it in ``AGUIStrandsAgent``,
    and yields AG-UI events.
    """

    def __init__(self, router: PageContextRouter) -> None:
        self._agent_factories: dict[str, dict[str, Any]] = {}
        self._router = router

    def register_agent_factory(
        self,
        name: str,
        factory: AgentFactory,
        description: str = "",
        config: StrandsAgentConfig | None = None,
    ) -> None:
        """Register an agent factory for on-demand agent creation.

        Args:
            name: Unique agent name (must match registry name).
            factory: Callable that accepts optional headers dict and
                returns a pre-configured Strands Agent.
            description: Human-readable description.
            config: Optional tool-behavior configuration.
        """
        self._agent_factories[name] = {
            "factory": factory,
            "description": description,
            "config": config,
        }
        log_info_event(
            logger,
            f"Registered agent factory '{name}' in orchestrator",
            "orchestrator.agent_factory_registered",
            agent_name=name,
        )

    async def run(
        self,
        input_data: RunAgentInput,
        agent_name: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> AsyncIterator[Any]:
        """Yield AG-UI events for *input_data*.

        If *agent_name* is ``None`` the orchestrator extracts ``page_context``
        from *input_data* and uses :class:`PageContextRouter` to resolve the
        target agent.

        Args:
            input_data: AG-UI ``RunAgentInput``.
            agent_name: Explicit agent name (skips routing).
            headers: Optional HTTP headers to forward to the MCP server
                (e.g. Authorization for OpenSearch authentication).

        Yields:
            AG-UI protocol events.
        """
        if agent_name is None:
            page_context = _extract_page_context(input_data)
            registration = self._router.route(page_context)
            agent_name = registration.name
            log_debug_event(
                logger,
                f"Routed page_context='{page_context}' -> agent='{agent_name}'",
                "orchestrator.routed",
                page_context=page_context,
                agent_name=agent_name,
            )

        factory_info = self._agent_factories.get(agent_name)
        if factory_info is None:
            raise RuntimeError(
                f"No agent factory registered with name '{agent_name}'. "
                f"Available: {list(self._agent_factories)}"
            )

        # Create a fresh agent with the request's auth headers
        strands_agent = factory_info["factory"](headers)
        agui_agent = AGUIStrandsAgent(
            agent=strands_agent,
            name=agent_name,
            description=factory_info["description"],
            config=factory_info["config"],
        )

        log_debug_event(
            logger,
            f"Created per-request agent '{agent_name}' "
            f"(with_auth_headers={headers is not None})",
            "orchestrator.agent_created",
            agent_name=agent_name,
            with_auth_headers=headers is not None,
        )

        async for event in agui_agent.run(input_data):
            yield event
