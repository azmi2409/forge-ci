import React from 'react';
import { createRoot } from 'react-dom/client';
import {
  ReactFlow, Background, Controls, Handle, Position, MarkerType
} from '@xyflow/react';

const h = React.createElement;
const statusColors = {
  success: 'status-ok',
  failed: 'status-error',
  running: 'status-pending',
  queued: 'status-pending',
  claimed: 'status-pending'
};
const color = status => `var(--${statusColors[status] || 'subtle'})`;
const label = status => status.charAt(0).toUpperCase() + status.slice(1);
const dot = status => h('span', { className: 'status-dot', 'data-state': status });

function CpuIcon() {
  return h('svg', {
    className: 'icon', viewBox: '0 0 24 24', fill: 'none',
    stroke: 'currentColor', strokeWidth: 1.7,
    strokeLinecap: 'round', strokeLinejoin: 'round', 'aria-hidden': true
  }, h('path', {
    d: 'M6 4h12v16H6z M6 8h12 M6 16h12 M2 9h4 M2 15h4 M18 9h4 M18 15h4'
  }));
}

function ParallelNodes({ data }) {
  return h('div', {
    className: 'nodes nodrag nopan',
    'aria-label': `Parallel nodes of ${data.name}`
  }, data.nodes.map(node => h('a', {
    key: node.index,
    href: node.href,
    title: `${data.name} #${node.index}: ${label(node.status)}`
  }, dot(node.status), node.index)));
}

function JobNode({ data }) {
  return h('div', {
    className: 'flow-job', style: { '--job-state': color(data.status) }
  },
  data.requires.map((name, index) => h(Handle, {
    key: name,
    id: name,
    type: 'target',
    position: data.long_requires.includes(name) ? Position.Bottom : Position.Left,
    style: data.long_requires.includes(name)
      ? { left: `${(index + 1) * 100 / (data.requires.length + 1)}%` }
      : { top: `${(index + 1) * 100 / (data.requires.length + 1)}%` }
  })),
  data.stage_start && h('div', { className: 'flow-stage' }, `Stage ${data.stage + 1}`),
  h('a', {
    href: data.href, className: 'jobnode', title: `Open ${data.name}`
  },
  h('div', { className: 'jobnode-top' },
    h('span', { className: 'jobnode-name truncate' }, data.name),
    h('span', { className: 'status-badge' }, dot(data.status), label(data.status))),
  h('div', { className: 'jobnode-meta' },
    h('span', null, h(CpuIcon), data.resource_class),
    data.parallel > 1 && h('span', null, `${data.parallel} parallel`))),
  data.parallel > 1 && h(ParallelNodes, { data }),
  h(Handle, { type: 'source', position: Position.Right }));
}

const nodeTypes = { job: JobNode };
for (const container of document.querySelectorAll('[data-workflow-diagram]')) {
  try {
    const graph = JSON.parse(container.dataset.workflowDiagram);
    if (!graph.nodes.length) continue;
    const fallback = container.nextElementSibling;
    container.className = 'pipeline-diagram';

    function viewport() {
      const zoom = Math.min(1, (container.clientWidth - 48) / graph.width);
      container.style.height = `${graph.height * zoom + 100}px`;
      return { x: (container.clientWidth - graph.width * zoom) / 2, y: 42, zoom };
    }

    const initialViewport = viewport();
    const edges = graph.edges.map(edge => ({
      ...edge,
      style: { stroke: color(edge.data.status), strokeWidth: 1.5 },
      markerEnd: {
        type: MarkerType.ArrowClosed,
        color: color(edge.data.status),
        width: 16,
        height: 16
      }
    }));

    createRoot(container).render(h(ReactFlow, {
      nodes: graph.nodes,
      edges,
      nodeTypes,
      defaultViewport: initialViewport,
      minZoom: 0.2,
      maxZoom: 1.6,
      nodesDraggable: false,
      nodesConnectable: false,
      elementsSelectable: false,
      zoomOnDoubleClick: false,
      preventScrolling: false,
      onNodeClick: (event, node) => {
        if (!event.target.closest('a')) window.location.assign(node.data.href);
      },
      onInit: flow => {
        fallback.hidden = true;
        const observer = new ResizeObserver(() => flow.setViewport(viewport()));
        observer.observe(container);
        window.addEventListener('pagehide', () => observer.disconnect(), { once: true });
      },
      onError: () => { fallback.hidden = false; }
    },
    h(Background, { gap: 20, size: 1, color: 'var(--line-strong)' }),
    h(Controls, { showInteractive: false, position: 'bottom-left' })));
  } catch (error) {
    container.removeAttribute('style');
    container.nextElementSibling.hidden = false;
    console.warn('Workflow diagram unavailable', error);
  }
}
