import React from 'react';
import { createRoot } from 'react-dom/client';
import { ReactFlow, Background, Controls, Handle, Position, Panel } from '@xyflow/react';

const h = React.createElement;
const color = status => `var(--${({ success: 'status-ok', failed: 'status-error', running: 'status-pending', queued: 'status-pending', claimed: 'status-pending' })[status] || 'subtle'})`;
const label = status => status.charAt(0).toUpperCase() + status.slice(1);
const dot = status => h('span', { className: 'status-dot', 'data-state': status });

function JobNode({ data }) {
  return h('div', { className: 'flow-job', style: { '--job-state': color(data.status) } },
    h(Handle, { type: 'target', position: Position.Left }),
    data.stage_start && h('div', { className: 'flow-stage' }, `Stage ${data.stage + 1}`),
    h('a', { href: data.href, className: 'jobnode', title: `Open ${data.name}` },
      h('div', { className: 'jobnode-top' },
        h('span', { className: 'jobnode-name truncate' }, data.name),
        h('span', { className: 'status-badge' }, dot(data.status), label(data.status))),
      h('div', { className: 'jobnode-meta' },
        h('span', null, h('svg', { className: 'icon', viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.5, 'aria-hidden': true },
          h('rect', { x: 5, y: 5, width: 14, height: 14, rx: 2 }), h('path', { d: 'M9 1v4m6-4v4M9 19v4m6-4v4M1 9h4m-4 6h4m14-6h4m-4 6h4M9 9h6v6H9z' })), data.resource_class),
        data.parallel > 1 && h('span', null, `${data.parallel} parallel`))),
    data.parallel > 1 && h('div', { className: 'nodes nodrag nopan', 'aria-label': `Parallel nodes of ${data.name}` },
      data.nodes.map(node => h('a', { key: node.index, href: node.href, title: `${data.name} #${node.index}: ${label(node.status)}` }, dot(node.status), node.index))),
    h(Handle, { type: 'source', position: Position.Right }));
}

const nodeTypes = { job: JobNode };
for (const container of document.querySelectorAll('[data-workflow-diagram]')) {
  try {
    const graph = JSON.parse(container.dataset.workflowDiagram);
    if (!graph.nodes.length) continue;
    const fallback = container.nextElementSibling;
    container.className = 'pipeline-diagram';
    container.style.height = `${graph.height}px`;
    const edges = graph.edges.map(edge => ({ ...edge, style: { stroke: color(edge.data.status), strokeWidth: 1.5 } }));
    createRoot(container).render(h(ReactFlow, {
      nodes: graph.nodes, edges, nodeTypes, fitView: true, fitViewOptions: { padding: 0.12, maxZoom: 1 },
      minZoom: 0.2, maxZoom: 1.6, nodesDraggable: false, nodesConnectable: false,
      elementsSelectable: false, zoomOnDoubleClick: false, preventScrolling: false,
      onNodeClick: (event, node) => { if (!event.target.closest('a')) window.location.assign(node.data.href); },
      onInit: () => { fallback.hidden = true; },
      onError: () => { fallback.hidden = false; }
    },
    h(Background, { gap: 20, size: 1, color: 'var(--line-strong)' }),
    h(Controls, { showInteractive: false, position: 'bottom-right' }),
    h(Panel, { position: 'top-left', className: 'flow-caption' },
      h('span', null, 'WORKFLOW MAP'), h('span', null, `${graph.nodes.length} jobs · ${graph.edges.length} dependencies`)),
    h(Panel, { position: 'bottom-left', className: 'flow-hint' }, 'Drag to pan · Scroll to zoom · Select a job to inspect')));
  } catch (error) {
    container.removeAttribute('style');
    container.nextElementSibling.hidden = false;
    console.warn('Workflow diagram unavailable', error);
  }
}
