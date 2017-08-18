import React, {PropTypes} from 'react';

import {t} from '../../locale';
import {Event} from '../../proptypes';

import Pagination from '../../components/pagination';
import MergedItem from './mergedItem';
import MergedToolbar from './mergedToolbar';

const MergedList = React.createClass({
  propTypes: {
    onUnmerge: PropTypes.func.isRequired,
    onCollapse: PropTypes.func.isRequired,
    items: PropTypes.arrayOf(Event),
    pageLinks: PropTypes.string
  },

  renderEmpty() {
    return (
      <div className="box empty-stream">
        <span className="icon icon-exclamation" />
        <p>{t("There don't seem to be any hashes for this issue.")}</p>
      </div>
    );
  },

  render() {
    let {items, pageLinks, onCollapse, onUnmerge, ...otherProps} = this.props;
    let hasResults = items.length > 0;

    if (hasResults) {
      return (
        <div className="fingerprint-list-container">
          <MergedToolbar onCollapse={onCollapse} onUnmerge={onUnmerge} />

          <div className="fingerprint-list">
            {items.map(({id, latestEvent}) => (
              <MergedItem
                key={id}
                {...otherProps}
                disabled={items.length === 1}
                event={latestEvent}
                fingerprint={id}
                itemCount={items.length}
              />
            ))}
          </div>
          <Pagination pageLinks={pageLinks} />
        </div>
      );
    }

    return this.renderEmpty();
  }
});

export default MergedList;
