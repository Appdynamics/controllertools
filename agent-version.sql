--
-- create a temporary table that gives us all the node id's that have
-- reported in the last 30 days.
--

create temporary table 
	active_node_ids 
as select 
	distinct node_id 
from 
	metricdata_hour
where
	ts_min > (select max(ts_min) from metricdata_hour) - 1440 * 30
;
		
--
-- count all distinct agent versions that are used by the above active
-- nodes
--

select 
	concat(a.major_release,'.',a.minor_release,'.', 
		a.point_release,'.',a.agent_point_release) as compat,
	left(a.agent_version, 60) as version,
	count(*)
from
	agent a,
	application_component_node_agent_mapping acnam,
	active_node_ids act
where
	act.node_id = acnam.application_component_node_id and
	acnam.agent_id = a.id
group by 
	1,2;

--
-- find all the active agents that are running 4.4.1.0
-- tell us how to find them
--

select
	app.name, tier.name, node.name,
	mi.name, mi.ip_address, mi.internal_name
from
	machine_instance mi,
	application app,
	application_component tier,
	application_component_node node,
	application_component_node_agent_mapping acnam,
	agent a,
	active_node_ids act
where
	act.node_id = acnam.application_component_node_id and
	act.node_id = node.id and
	acnam.agent_id = a.id and
	node.machine_instance_id = mi.id and
	app.id = tier.application_id and
	tier.id = node.application_component_id and
	a.major_release = 4 and
	a.minor_release = 4 and
	a.point_release = 1 and
	a.agent_point_release = 0;
	
