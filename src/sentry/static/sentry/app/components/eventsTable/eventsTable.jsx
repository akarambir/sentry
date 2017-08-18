import React, {PropTypes} from 'react';
import classNames from 'classnames';

import {t} from '../../locale';
import CustomPropTypes from '../../proptypes';
import EventsTableRow from './eventsTableRow';
import '../../../less/components/eventsTable/eventsTable.less';

const EventsTable = React.createClass({
  propTypes: {
    events: PropTypes.arrayOf(CustomPropTypes.Event),
    tagList: PropTypes.arrayOf(CustomPropTypes.Tag)
  },

  getDefaultProps() {
    return {};
  },

  render() {
    let {className, events, tagList} = this.props;

    let cx = classNames('table events-table', className);
    let hasUser = !!events.find(event => event.user);
    let {orgId, projectId, groupId} = this.props.params;

    return (
      <table className={cx}>
        <thead>
          <tr>
            <th>{t('ID')}</th>
            {hasUser && <th>{t('User')}</th>}

            {tagList.map(tag => {
              return (
                <th key={tag.key}>
                  {tag.name}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {events.map(event => {
            let tagMap = {};
            event.tags.forEach(tag => {
              tagMap[tag.key] = tag.value;
            });
            return (
              <EventsTableRow
                key={event.id}
                event={event}
                orgId={orgId}
                projectId={projectId}
                groupId={groupId}
                tagList={tagList}
                tagMap={tagMap}
                hasUser={hasUser}
              />
            );
          })}
        </tbody>
      </table>
    );
  }
});

export default EventsTable;
